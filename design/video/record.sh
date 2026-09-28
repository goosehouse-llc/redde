#!/bin/zsh
# record.sh <name> <seconds> <launch args...>   records a plain launch
# record.sh --test <name> <TestName>           records a PromoVideoUITests test, prints its marks
set -u
S=${SIM:-"iPhone 17 Pro Max"}   # a UDID works too
V=${0:A:h}
cd "$V/../.."
now() { /usr/bin/python3 -c 'import time; print(time.time())'; }
if [[ $1 == --test ]]; then
  name=$2; test=$3
  xcrun simctl io $S recordVideo --codec=h264 --force $V/$name.mov > $V/$name.rec.log 2>&1 &
  rec=$!; sleep 1.2; t0=$(now)
  TEST_RUNNER_PROMO_VIDEO=1 xcodebuild -project Echo.xcodeproj -scheme EchoUITests -destination "id=$S" \
    -derivedDataPath DerivedData test-without-building -only-testing:EchoUITests/PromoVideoUITests/$test > $V/$name.test.log 2>&1
  kill -INT $rec; wait $rec 2>/dev/null
  echo "t0 $t0"; grep -a -o "PROMO [a-z]* [0-9.]*" $V/$name.test.log | sort -u; grep -a -E "passed|failed|skipped" $V/$name.test.log | head -3
else
  name=$1; secs=$2; shift 2
  xcrun simctl terminate $S com.goosehouse.echo 2>/dev/null
  xcrun simctl io $S recordVideo --codec=h264 --force $V/$name.mov > $V/$name.rec.log 2>&1 &
  rec=$!; sleep 1.2; t0=$(now)
  xcrun simctl launch $S com.goosehouse.echo -setupDone YES -openToVoiceScreen NO -listenOnOpen NO -requireBiometrics NO \
    -echo.demoHosts -transport chatCompletions "$@" > /dev/null
  t1=$(now); sleep $secs
  kill -INT $rec; wait $rec 2>/dev/null
  echo "t0 $t0"; echo "launched $t1"
fi
