#!/bin/sh
# Fursoy Slice-2 Milestone S2-M5 SMP Linux + BusyBox Userspace Validation Init
exec 0</dev/console 1>/dev/console 2>/dev/console
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc none /proc 2>/dev/null || true
mount -t sysfs none /sys 2>/dev/null || true
mkdir -p /tmp /dev /run

echo "===================================================="
echo "[INIT] Fursoy Slice-2 SMP Linux BusyBox Userspace active!"
echo "===================================================="
echo "FURSOY_USERSPACE_BEGIN"

fail() {
    echo "FURSOY_USERSPACE_FAIL: $1"
    echo "[S2_M5_LINUX_FAIL] $1"
    while true; do sleep 10; done
}

# 1. Verify /proc/cpuinfo reports N >= 2 online processors (0..N-1)
echo "[SMP 01] Checking /proc/cpuinfo & /sys/devices/system/cpu/online"
cat /proc/cpuinfo || fail "cat /proc/cpuinfo failed"
CPU_COUNT=$(grep -c '^processor' /proc/cpuinfo)
ONLINE_STR=$(cat /sys/devices/system/cpu/online 2>/dev/null || echo "unknown")
echo "CPUINFO_ONLINE=${CPU_COUNT} SYS_ONLINE=${ONLINE_STR}"
[ "$CPU_COUNT" -ge 2 ] || fail "Expected >= 2 online CPUs, got ${CPU_COUNT}"
IDX=0
while [ "$IDX" -lt "$CPU_COUNT" ]; do
    grep -q "^processor[[:space:]]*:[[:space:]]*${IDX}\$" /proc/cpuinfo || fail "Missing processor ${IDX} in /proc/cpuinfo"
    IDX=$(( IDX + 1 ))
done
echo "[SMP_CPUINFO_PASS] online=${CPU_COUNT}"

ISA_LINE=$(grep -m1 '^isa' /proc/cpuinfo || echo "")
echo "CPUINFO_ISA=${ISA_LINE}"
echo "$ISA_LINE" | grep -q 'rv64imafd' || fail "Expected rv64imafd in /proc/cpuinfo isa (${ISA_LINE})"
if echo "$ISA_LINE" | grep -qE 'rv64imafd[a-z]*[cv]'; then
    fail "Unexpected c or v advertised in /proc/cpuinfo isa (${ISA_LINE})"
fi
echo "[SMP_ISA_PASS] ${ISA_LINE}"

# 2. Verify taskset (if BusyBox applet present) + C sched_setaffinity + pthreads/stdatomic
if command -v taskset >/dev/null 2>&1; then
    echo "[SMP 02] Exercising BusyBox taskset across CPUs 0..$(( CPU_COUNT - 1 ))"
    IDX=0
    while [ "$IDX" -lt "$CPU_COUNT" ]; do
        MASK=$(( 1 << IDX ))
        taskset "$MASK" sh -c "echo taskset_cpu_${IDX}_ok" || fail "taskset failed on CPU ${IDX}"
        IDX=$(( IDX + 1 ))
    done
fi

echo "[SMP 03] Running /bin/s2_smp_test (sched_setaffinity + pthreads + C11 stdatomic)"
/bin/s2_smp_test || fail "s2_smp_test failed"

# 3. BusyBox SMP Regression Suite
echo "[SMP 04] Running BusyBox regression suite under CONFIG_SMP=y"
uname -a || fail "uname failed"
VAR="slice2_smp_rv64"
[ "$VAR" = "slice2_smp_rv64" ] || fail "variable expansion failed"
ARITH=$(( 100 + 200 - 50 ))
[ "$ARITH" -eq 250 ] || fail "arithmetic failed"

echo "initial smp content" > /tmp/smp_testfile || fail "file creation failed"
[ "$(cat /tmp/smp_testfile)" = "initial smp content" ] || fail "file readback failed"
echo "appended smp line" >> /tmp/smp_testfile || fail "file append failed"
mkdir -p /tmp/smp_dir/sub1/sub2 || fail "mkdir -p failed"
ls -la /tmp/smp_dir/sub1 > /tmp/smp_ls.out || fail "ls failed"
[ -s /tmp/smp_ls.out ] || fail "ls output empty"
cp /tmp/smp_testfile /tmp/smp_cp || fail "cp failed"
mv /tmp/smp_cp /tmp/smp_mv || fail "mv failed"
rm -f /tmp/smp_mv || fail "rm failed"
rmdir /tmp/smp_dir/sub1/sub2 || fail "rmdir failed"

P_OUT=$(echo -e "gamma\nalpha\nbeta" | grep "alpha" | cat)
[ "$P_OUT" = "alpha" ] || fail "pipeline failed"

COUNT=0
for i in 1 2 3 4 5; do
    sh -c "exit 0" || fail "subshell failed on iter $i"
    COUNT=$(( COUNT + 1 ))
done
[ "$COUNT" -eq 5 ] || fail "subshell count mismatch"

if [ -x /bin/mem_stress ]; then
    /bin/mem_stress || fail "mem_stress failed"
fi

echo "[SMP_BUSYBOX_PASS]"
echo "FURSOY_USERSPACE_PASS"
echo "===================================================="
echo "[S2_M5_LINUX_ALL_PASS] online=${CPU_COUNT}"
echo "===================================================="

# Trigger clean poweroff via SBI SRST if supported, otherwise park
poweroff -f 2>/dev/null || true
while true; do
    sleep 10
done
