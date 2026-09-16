#!/bin/sh
# Ensure stdio connected to console
exec 0</dev/console 1>/dev/console 2>/dev/console
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

# Mount virtual filesystems
mount -t proc none /proc 2>/dev/null || true
mount -t sysfs none /sys 2>/dev/null || true
mkdir -p /tmp /dev /run

echo "===================================================="
echo "[INIT] Fursoy Slice-0 Linux BusyBox Userspace active!"
echo "===================================================="
echo "FURSOY_USERSPACE_BEGIN"

fail() {
    echo "FURSOY_USERSPACE_FAIL: $1"
    while true; do sleep 10; done
}

echo "[TEST 01] uname"
uname -a || fail "uname failed"

echo "[TEST 02] echo"
echo "echo test string" || fail "echo failed"

echo "[TEST 03] shell variable assignment/expansion"
VAR="slice0_rv64"
[ "$VAR" = "slice0_rv64" ] || fail "variable expansion failed"

echo "[TEST 04] arithmetic"
ARITH=$(( 100 + 200 - 50 ))
[ "$ARITH" -eq 250 ] || fail "arithmetic failed"

echo "[TEST 05] file creation"
echo "initial content" > /tmp/testfile || fail "file creation failed"

echo "[TEST 06] file readback"
READBACK=$(cat /tmp/testfile)
[ "$READBACK" = "initial content" ] || fail "file readback failed"

echo "[TEST 07] file overwrite"
echo "second content" > /tmp/testfile || fail "file overwrite failed"
[ "$(cat /tmp/testfile)" = "second content" ] || fail "file overwrite readback failed"

echo "[TEST 08] file append"
echo "appended line" >> /tmp/testfile || fail "file append failed"

echo "[TEST 09] directory creation"
mkdir -p /tmp/testdir/sub1/sub2 || fail "mkdir -p failed"

echo "[TEST 10] directory listing"
ls -la /tmp/testdir/sub1 > /tmp/ls.out || fail "ls failed"
[ -s /tmp/ls.out ] || fail "ls output empty"

echo "[TEST 11] cat"
cat /tmp/testfile > /tmp/cat.out || fail "cat failed"
[ -s /tmp/cat.out ] || fail "cat output empty"

echo "[TEST 12] cp"
cp /tmp/testfile /tmp/testfile_cp || fail "cp failed"
[ -f /tmp/testfile_cp ] || fail "cp target not found"

echo "[TEST 13] mv"
mv /tmp/testfile_cp /tmp/testfile_mv || fail "mv failed"
[ -f /tmp/testfile_mv ] || fail "mv target not found"
[ ! -f /tmp/testfile_cp ] || fail "mv source still exists"

echo "[TEST 14] rm"
rm -f /tmp/testfile_mv || fail "rm failed"
[ ! -f /tmp/testfile_mv ] || fail "rm target still exists"

echo "[TEST 15] mkdir / rmdir"
mkdir /tmp/test_rmdir || fail "mkdir failed"
rmdir /tmp/test_rmdir || fail "rmdir failed"
[ ! -d /tmp/test_rmdir ] || fail "rmdir directory still exists"

echo "[TEST 16] test utility"
test -d /tmp && test ! -f /tmp/nonexistent || fail "test utility failed"

echo "[TEST 17] pipelines"
P_OUT=$(echo -e "gamma\nalpha\nbeta" | grep "alpha" | cat)
[ "$P_OUT" = "alpha" ] || fail "pipeline failed"

echo "[TEST 18] shell loops"
SUM=0
for i in 1 2 3 4 5; do
    SUM=$(( SUM + i ))
done
[ "$SUM" -eq 15 ] || fail "shell loop failed"

echo "[TEST 19] shell conditional branches"
if [ "$SUM" -eq 15 ]; then
    BRANCH_OK=1
else
    BRANCH_OK=0
fi
[ "$BRANCH_OK" -eq 1 ] || fail "conditional branch failed"

echo "[TEST 20] repeated process creation/exit"
COUNT=0
for i in 1 2 3 4 5; do
    sh -c "exit 0" || fail "process creation failed on iteration $i"
    COUNT=$(( COUNT + 1 ))
done
[ "$COUNT" -eq 5 ] || fail "process creation count mismatch"

echo "[TEST 21] userspace memory stress"
/bin/mem_stress || fail "mem_stress execution failed"

echo "===================================================="
echo "[SUCCESS] All userspace smoke and memory checks passed!"
echo "FURSOY_USERSPACE_PASS"
echo "===================================================="

while true; do
    sleep 10
done
