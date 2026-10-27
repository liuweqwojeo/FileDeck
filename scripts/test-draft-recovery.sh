#!/bin/bash
# 所有源码/资源/进程/恢复目录均为本次独立副本，writer 检查点就绪后才允许精确 SIGKILL。
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/build/draft-recovery-tests"
mkdir -p "$OUTPUT_DIR/module-cache"
RUN_DIR="$(mktemp -d "$OUTPUT_DIR/run.XXXXXX")"
APP_DIR="$RUN_DIR/DraftRecoveryTests.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$RUN_DIR/sources" "$RUN_DIR/fixtures" "$RUN_DIR/preferences-home"
/usr/bin/ditto "$PROJECT_DIR/Resources/Editors" "$APP_DIR/Contents/Resources/FileWorkbenchEditors"
export FW_DRAFTS_TEST_ROOT="$RUN_DIR/fixtures"
export FW_DRAFTS_TEST_TOKEN="$(uuidgen)"
export FW_OFFICE_SMOKE_DIR="$RUN_DIR/fixtures"
export FW_OFFICE_SMOKE_TOKEN="$FW_DRAFTS_TEST_TOKEN"
export CFFIXED_USER_HOME="$RUN_DIR/preferences-home"
python3 -B - "$APP_DIR/Contents/Info.plist" <<'PY'
import plistlib,sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({'CFBundleExecutable':'DraftRecoveryTests',
 'CFBundleIdentifier':'local.fileworkbench.draft-recovery-tests','CFBundlePackageType':'APPL',
 'NSPrincipalClass':'NSApplication','LSMinimumSystemVersion':'14.0'}))
PY
python3 -B - "$PROJECT_DIR" "$RUN_DIR" <<'PY'
import hashlib,json,sys
from pathlib import Path
root,run=map(Path,sys.argv[1:])
inputs=[p for p in (root/'Sources/FileWorkbench').glob('*.swift') if p.name!='FileWorkbenchApp.swift']
inputs+=list((root/'NativeOffice/Workbench').glob('*.swift'))
inputs+=[root/'scripts/test-draft-recovery.swift']
records=[]
for source in inputs:
 data=source.read_bytes();(run/'sources'/source.name).write_bytes(data)
 records.append({'source':str(source),'sha256':hashlib.sha256(data).hexdigest()})
(run/'source-manifest.json').write_text(json.dumps(records,indent=2)+'\n')
PY
if ! swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos14 \
    -module-cache-path "$OUTPUT_DIR/module-cache" "$RUN_DIR"/sources/*.swift \
    -o "$APP_DIR/Contents/MacOS/DraftRecoveryTests" > "$RUN_DIR/build.log" 2>&1; then
    cat "$RUN_DIR/build.log"
    exit 1
fi
set +e
"$APP_DIR/Contents/MacOS/DraftRecoveryTests" > "$RUN_DIR/unguarded-launch.log" 2>&1
LAUNCH_STATUS=$?
set -e
if [[ "$LAUNCH_STATUS" -ne 64 ]]; then
    cat "$RUN_DIR/unguarded-launch.log"
    exit 1
fi
python3 -B - "$APP_DIR/Contents/MacOS/DraftRecoveryTests" "$RUN_DIR/fixtures" <<'PY'
import hashlib,json,os,signal,subprocess,sys,time
from pathlib import Path
binary,fixtures=map(Path,sys.argv[1:])
run=fixtures.parent

def start(mode):
 log=(run/(mode+'.log')).open('w')
 child=subprocess.Popen([str(binary),mode,str(fixtures)],stdout=log,stderr=subprocess.STDOUT)
 (run/(mode+'-pid.json')).write_text(json.dumps({'pid':child.pid,'executable':str(binary)}))
 return child,log

def activate(child,mode):
 # 只操作本 Popen 创建的子进程，先核验其当前可执行路径；没有窗口时不抢其他窗口焦点。
 state=subprocess.run(['/bin/ps','-p',str(child.pid),'-o','comm='],capture_output=True,text=True)
 if state.returncode or state.stdout.strip()!=str(binary): return False
 script='tell application "System Events"\nset testProcess to first application process whose unix id is '+str(child.pid)+'\nif (count of windows of testProcess) > 0 then\nset frontmost of testProcess to true\nreturn frontmost of testProcess\nend if\nend tell'
 result=subprocess.run(['osascript','-e',script],capture_output=True,text=True,timeout=10)
 if result.returncode==0 and result.stdout.strip()=='true':
  (run/(mode+'-activation.json')).write_text(json.dumps({'pid':child.pid,'executable':str(binary),'frontmost':True},indent=2)+'\n')
  return True
 return False

writer,writer_log=start('writer')
activated=False
deadline=time.monotonic()+110
try:
 while not (fixtures/'checkpoint-ready.json').exists():
  if writer.poll() is not None: raise RuntimeError('writer 提前退出，未得到可恢复的检查点')
  if not activated: activated=activate(writer,'writer')
  if time.monotonic()>deadline: raise TimeoutError('writer 检查点超时')
  time.sleep(.2)
 # 发送信号前再次核验 PID 和可执行文件，绝不按应用名称杀进程。
 state=subprocess.run(['/bin/ps','-p',str(writer.pid),'-o','comm='],capture_output=True,text=True)
 if state.returncode or state.stdout.strip()!=str(binary): raise RuntimeError('writer 身份变化，拒绝终止')
 writer.send_signal(signal.SIGKILL)
 status=writer.wait(timeout=10)
 if status!=-signal.SIGKILL: raise RuntimeError('writer 未按预期由 SIGKILL 退出')
 (run/'crash.json').write_text(json.dumps({'writerPID':writer.pid,'signal':'SIGKILL','returnCode':status,
  'checkpointReady':True,'executable':str(binary)},indent=2)+'\n')
finally:
 if writer.poll() is None: writer.terminate();writer.wait(timeout=10)
 writer_log.close()

# 模拟崩溃后原文件变化，恢复绝不能以这些路径重新读取/覆盖原内容。
(fixtures/'original.md').write_text('# external replacement\n')
(fixtures/'original.csv').unlink()
(fixtures/'original.pdf').rename(fixtures/'external-original.pdf')
(fixtures/'original.png').write_bytes(b'external image replacement')
external={}
for name in ['original.md','original.csv','original.pdf','original.png','cleanup.txt','external-original.pdf']:
 path=fixtures/name
 external[name]=hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else 'missing'
(fixtures/'external-sources.json').write_text(json.dumps(external,indent=2)+'\n')
reader,reader_log=start('reader')
activated=False
deadline=time.monotonic()+110
try:
 while reader.poll() is None:
  if not activated: activated=activate(reader,'reader')
  if time.monotonic()>deadline: raise TimeoutError('reader 恢复验收超时')
  time.sleep(.2)
 reader_status=reader.wait()
finally:
 if reader.poll() is None: reader.terminate();reader.wait(timeout=10)
 reader_log.close()
print((run/'writer.log').read_text())
print((run/'reader.log').read_text())
report=json.loads((fixtures/'reader-report.json').read_text())
if reader_status or not report['passed']: raise RuntimeError('恢复验收失败，保留 '+str(run))
print('真实进程崩溃恢复报告：'+str(fixtures/'reader-report.json'))
PY
