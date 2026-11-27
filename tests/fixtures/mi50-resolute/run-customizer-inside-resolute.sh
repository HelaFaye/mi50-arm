#!/usr/bin/env bash
set -Eeuo pipefail

[ "$(dpkg --print-architecture)" = arm64 ]
mkdir -p /tmp/overlay /tmp/payload-root/opt/rocm/{bin,llvm/bin,lib}
cp /workspace/armbian/image/overlay/mi50-customize-image-resolute.sh \
  /tmp/overlay/mi50-customize-image.sh
cp -a /workspace/armbian/image/overlay/etc /tmp/overlay/
cp -a /workspace/armbian/image/overlay/usr /tmp/overlay/
chmod 0755 /tmp/overlay/mi50-customize-image.sh \
  /tmp/overlay/usr/local/sbin/mi50-set-power-cap \
  /tmp/overlay/usr/local/sbin/mi50-add-users-to-gpu-groups

# --root enables units offline without starting systemd in this container.
cat > /usr/local/sbin/systemctl <<'EOF'
#!/bin/sh
[ "$1" = "--root=/" ] && [ "$2" = "enable" ] || exit 2
printf '%s\n' "$*" > /run/mi50-systemctl-test.log
EOF
chmod 0755 /usr/local/sbin/systemctl

for rel in \
  opt/rocm/bin/hipcc \
  opt/rocm/bin/rocminfo \
  opt/rocm/llvm/bin/clang \
  opt/rocm/llvm/bin/clang++; do
  mkdir -p "/tmp/payload-root/$(dirname "$rel")"
  printf '#!/bin/sh\nexit 0\n' > "/tmp/payload-root/$rel"
  chmod 0755 "/tmp/payload-root/$rel"
done
ln -s ../llvm/bin/clang /tmp/payload-root/opt/rocm/bin/amdclang
ln -s ../llvm/bin/clang++ /tmp/payload-root/opt/rocm/bin/amdclang++
printf 'test shared object placeholder\n' > /tmp/payload-root/opt/rocm/lib/libamdhip64.so.6
printf 'test shared object placeholder\n' > /tmp/payload-root/opt/rocm/lib/libhsa-runtime64.so.1
ln -s libamdhip64.so.6 /tmp/payload-root/opt/rocm/lib/libamdhip64.so
ln -s libhsa-runtime64.so.1 /tmp/payload-root/opt/rocm/lib/libhsa-runtime64.so

tar -C /tmp/payload-root -czf /tmp/overlay/mi50-rocm-arm64.tar.gz opt/rocm

/tmp/overlay/mi50-customize-image.sh resolute rockchip64 orangepi5-plus yes

[ -x /opt/rocm/bin/hipcc ]
[ -x /opt/rocm/bin/rocminfo ]
[ "$(readlink /opt/rocm/bin/amdclang)" = "../llvm/bin/clang" ]
[ "$(readlink /opt/rocm/bin/amdclang++)" = "../llvm/bin/clang++" ]
[ -f /etc/mi50-rocm.env ]
[ -f /etc/profile.d/mi50-rocm.sh ]
[ -f /etc/ld.so.conf.d/mi50-rocm.conf ]
[ -f /etc/udev/rules.d/70-mi50-rocm.rules ]
[ -f /etc/systemd/system/mi50-power-cap.service ]
[ -f /etc/systemd/system/mi50-device-access.timer ]
grep -Fq -- '--root=/ enable mi50-power-cap.service mi50-device-access.timer' \
  /run/mi50-systemctl-test.log

for package in libdrm2 libdrm-amdgpu1 libelf1t64 libnuma1 libzstd1 zlib1g; do
  # shellcheck disable=SC2016 # dpkg-query needs its own format variable expansion.
  dpkg-query -W -f='${db:Status-Status}' "$package" | grep -qx installed
done

# A payload containing anything outside opt/rocm must be rejected before use.
mkdir -p /tmp/unsafe-payload
printf x > /tmp/unsafe-payload/not-rocm.txt
tar -C /tmp/unsafe-payload -czf /tmp/overlay/mi50-rocm-arm64.tar.gz .
if /tmp/overlay/mi50-customize-image.sh resolute rockchip64 orangepi5-plus yes \
    >/tmp/mi50-invalid-payload.log 2>&1; then
  echo "unsafe payload unexpectedly passed validation" >&2
  exit 1
fi
grep -q "payload contains unsafe paths" /tmp/mi50-invalid-payload.log

printf 'PASS: Resolute ARM64 apt dependency installation\n'
printf 'PASS: ROCm payload extraction and relative compiler aliases\n'
printf 'PASS: MI50 profile, udev, systemd, and helper installation\n'
printf 'PASS: unsafe archive path rejected\n'
