# 错误串口退出崩溃修复

## 证据和原因

本机 Windows Application / Event 1000 有两条 ink_studio.exe 0.4.0.8 崩溃记录，模块 ntdll.dll，异常 0xc0000374（堆损坏）。本次没有 dump 调用栈，无法从事件单独定位分配地址；源码确认的 double-free 与该症状一致。

锁定的 Dart libserialport 0.3.0+1 `port.dart`：config setter 在调用 sp_set_config 前将传入对象保存到 `_config`；SerialPort.dispose 会调用 `_config.dispose`。原应用给 port.config 赋值后在 finally 中执行 config.dispose，端口清理时再次释放同一原生地址。

错误串口能成功打开但不响应 SEP/1 时，2 秒发现超时后关闭端口便会触发；配置失败的异常清理和正常断开同样存在风险。Dart isolate 与 UI 共用进程，无法隔离原生堆损坏。增加 try/catch 或延长超时不能修复 double-free。

## 修正

配置前异常由调用方释放；进入 config setter 后由 port 独占释放，即使底层应用配置失败也不能再次释放。抽取 configureDesktopPort，使实际生产路径和测试使用相同所有权逻辑。构造失败时 close 放入 try/finally，保证 dispose 能执行。

## 验证边界

- 配置成功与 setter 失败分别循环 100 次，模拟绑定的接管顺序，断言只释放一次。
- 配置准备失败验证未转移对象仍被释放。
- 控制器连接返回非 SEP 数据的端口，测试两次超时/关闭/重连以及写入异常，状态恢复且每次关闭一次。
- 35 项 C 固件/USB/协议测试通过；原 45 项 Flutter 加所有权 3 项通过，额外错误端口测试单独执行。
- 没有主动打开用户其他串口发送探测数据；真实串口复测与上述模拟测试分开。

后续升级 libserialport 时必须重新核对 config setter 的所有权约定。
