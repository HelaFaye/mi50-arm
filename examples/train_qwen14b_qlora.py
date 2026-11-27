"""Experimental QLoRA fine-tuning for Qwen2.5-14B on a 32 GB gfx906 MI50.

This is a hardware-dependent training example, not a CI test. Point MODEL_ID
and DATASET_PATH at local model/dataset directories (or set the environment
variables) before running it.
"""
import os

# gfx906 does not expose hardware dynamic VMM; do not enable expandable_segments.
os.environ["TORCH_BLAS_PREFER_HIPBLASLT"] = "0"
# Transformers 4.46.3 performs accumulation in Trainer itself. Keep the
# Accelerator-side divisor at one, even if the shell has an override configured.
os.environ["ACCELERATE_GRADIENT_ACCUMULATION_STEPS"] = "1"
os.environ["ROCBLAS_TENSILE_LIBPATH"] = os.environ.get(
    "ROCBLAS_TENSILE_LIBPATH", "/opt/rocm/lib/rocblas/library"
)
os.environ["TOKENIZERS_PARALLELISM"] = "false"
os.environ.setdefault("HSA_USERPTR_FOR_PAGED_MEM", "0")

import torch
import torch.nn.functional as F
from datasets import load_from_disk
from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig
from trl import SFTConfig, SFTTrainer

# Force the portable C++/HIP math SDPA path; don't select Flash or memory-efficient SDPA.
torch.backends.cuda.enable_flash_sdp(False)
torch.backends.cuda.enable_mem_efficient_sdp(False)
torch.backends.cuda.enable_math_sdp(True)

MODEL_ID = os.environ.get("MODEL_ID", "/path/to/Qwen2.5-14B")
DATASET_PATH = os.environ.get("DATASET_PATH", "/path/to/pretokenized_ds")
OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "./qwen25-14b-mi50-qlora")

if not os.path.isdir(MODEL_ID):
    raise SystemExit(f"MODEL_ID must be a local model directory: {MODEL_ID}")
if not os.path.isdir(DATASET_PATH):
    raise SystemExit(f"DATASET_PATH must be a saved dataset directory: {DATASET_PATH}")
if not torch.cuda.is_available() or not torch.version.hip:
    raise SystemExit("This training recipe requires the ROCm-enabled PyTorch build and a visible GPU")
print("Training device:", torch.cuda.get_device_name(0))

# Smoke-test with a small Qwen2.5 checkpoint and max_steps=20 before 14B training.
tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
if tokenizer.pad_token is None:
    tokenizer.pad_token = tokenizer.eos_token

bnb_config = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_quant_type="nf4",
    bnb_4bit_use_double_quant=True,
    bnb_4bit_compute_dtype=torch.float16,
)

model = AutoModelForCausalLM.from_pretrained(
    MODEL_ID,
    quantization_config=bnb_config,
    torch_dtype=torch.float16,
    attn_implementation="sdpa",
    low_cpu_mem_usage=True,
    device_map={"": 0},
)
# Gradient checkpointing and KV caching are mutually exclusive during training.
model.config.use_cache = False

model = prepare_model_for_kbit_training(
    model,
    use_gradient_checkpointing=True,
    gradient_checkpointing_kwargs={"use_reentrant": False},
)
for name, module in model.named_modules():
    if "norm" in name or name == "lm_head":
        module.to(torch.float16)

lora_config = LoraConfig(
    r=16,
    lora_alpha=32,
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
    lora_dropout=0.05,
    bias="none",
    task_type="CAUSAL_LM",
)
model = get_peft_model(model, lora_config)

# Keep trainable LoRA A/B weights in FP32 so GradScaler unscales cleanly.
for param in model.parameters():
    if param.requires_grad:
        param.data = param.data.to(torch.float32)

model.print_trainable_parameters()


class ChunkedFP32LossSFTTrainer(SFTTrainer):
    """Compute chunked FP32 loss with token-correct gradient accumulation."""

    def get_batch_samples(self, epoch_iterator, num_batches):
        """Count labels that actually contribute after the causal-LM one-token shift."""
        batch_samples = []
        for _ in range(num_batches):
            try:
                batch_samples.append(next(epoch_iterator))
            except StopIteration:
                break

        if not batch_samples or "labels" not in batch_samples[0]:
            return batch_samples, None

        device = self.args.device
        token_count = sum(
            int((batch["labels"][..., 1:] != -100).sum().item())
            for batch in batch_samples
        )
        if self.args.average_tokens_across_devices:
            count = torch.tensor(token_count, device=device, dtype=torch.long)
            token_count = int(self.accelerator.gather(count).sum().item())
        return batch_samples, token_count

    def compute_loss(self, model, inputs, return_outputs=False, num_items_in_batch=None):
        labels = inputs.pop("labels")
        outputs = model(**inputs)
        logits = outputs.logits

        shift_logits = logits[..., :-1, :].contiguous()
        shift_labels = labels[..., 1:].contiguous()
        _, _, vocab_size = shift_logits.shape
        flat_logits = shift_logits.view(-1, vocab_size)
        flat_labels = shift_labels.view(-1)

        total_tokens = flat_labels.numel()
        chunk_size = 256
        loss_sum = torch.zeros((), device=logits.device, dtype=torch.float32)
        valid_tokens = (flat_labels != -100).sum()

        for start in range(0, total_tokens, chunk_size):
            end = min(start + chunk_size, total_tokens)
            chunk_loss = F.cross_entropy(
                flat_logits[start:end].to(torch.float32),
                flat_labels[start:end],
                ignore_index=-100,
                reduction="sum",
            )
            loss_sum = loss_sum + chunk_loss

        if num_items_in_batch is not None:
            # Transformers 4.46.3 passes the shifted-token count for the whole
            # gradient-accumulation window. Trainer configures Accelerate with
            # gradient_accumulation_steps=1 and does not divide this loss before
            # backward(), so each microbatch contributes its token-loss sum divided
            # by the shared window denominator. Summed gradients are the global
            # shifted-token mean; do not multiply by gradient_accumulation_steps.
            denominator = torch.as_tensor(
                num_items_in_batch, device=logits.device, dtype=torch.float32
            )
            if denominator.item() <= 0:
                loss = loss_sum * 0.0
            else:
                # Accumulate each microbatch's loss-sum contribution against the
                # common window denominator, including uneven label masks.
                loss = loss_sum / denominator
            if self.args.average_tokens_across_devices:
                loss = loss * self.accelerator.num_processes
        else:
            # Fallback for Trainer configurations that do not provide a
            # cross-microbatch token count.
            loss = loss_sum / valid_tokens.clamp_min(1).to(torch.float32)

        return (loss, outputs) if return_outputs else loss


dataset = load_from_disk(DATASET_PATH)
training_args = SFTConfig(
    output_dir=OUTPUT_DIR,
    max_steps=int(os.environ.get("MAX_STEPS", "-1")),
    max_seq_length=1024,
    per_device_train_batch_size=1,
    gradient_accumulation_steps=16,
    gradient_checkpointing=True,
    gradient_checkpointing_kwargs={"use_reentrant": False},
    fp16=True,
    bf16=False,
    max_grad_norm=0.5,
    optim="adamw_torch",
    learning_rate=5e-5,
    lr_scheduler_type="cosine",
    warmup_ratio=0.05,
    dataloader_pin_memory=False,
    dataloader_num_workers=0,
    save_strategy="steps",
    save_steps=100,
    logging_steps=5,
    report_to="none",
)

trainer = ChunkedFP32LossSFTTrainer(
    model=model,
    args=training_args,
    train_dataset=dataset,
    processing_class=tokenizer,
)
# Tell Transformers to calculate num_items_in_batch across the complete
# accumulation window. The custom compute_loss consumes it and normalizes each
# microbatch's loss sum against that shared count; the underlying model does not
# accept loss_kwargs.
trainer.model_accepts_loss_kwargs = True
trainer.train()
trainer.save_model(f"{OUTPUT_DIR}/final-adapter")
