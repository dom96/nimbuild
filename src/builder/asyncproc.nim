import osproc, asyncdispatch, streams, strtabs

## Output format.
## --------------
##
## /curr/dir $ command --args
## Stdout output
## ! stderr output

type
  AsyncExecutor* = ref object
    thread: TThread[void]

  ProgressCB* = proc (message: ProcessEvent): Future[void]

  ThreadCommandKind = enum
    StartProcess, KillProcess

  ThreadCommand = object
    case kind: ThreadCommandKind
    of StartProcess:
      command: string
      workingDir: string
      args: seq[string]
      env: StringTableRef
    of KillProcess: nil

  ProcessEventKind* = enum
    ProcessStdout, ProcessStderr, ProcessEnd, CommandError

  ProcessEvent* = object
    case kind*: ProcessEventKind
    of ProcessStdout, ProcessStderr:
      data*: string
    of ProcessEnd:
      code*: int
    of CommandError:
      error: string

  AsyncExecutorError = object of Exception

var commandChan: TChannel[ThreadCommand]
open(commandChan)
var messageChan: TChannel[ProcessEvent]
open(messageChan)

proc newAsyncExecutor*(): AsyncExecutor =
  new result

proc executorThread() {.thread, raises: [DeadThreadError, Exception].} =
  try:
    var process: Process = nil
    var line = ""
    while true:
      # Check command channel.
      let (received, command) = 
        if process != nil: commandChan.tryRecv()
        else: (true, commandChan.recv())
      if received:
        case command.kind
        of StartProcess:
          try:
            process = startProcess(command.command, command.workingDir,
                                   command.args, command.env)
          except:
            let error = "Unable to launch process: " & getCurrentExceptionMsg()
            messageChan.send(ProcessEvent(kind: CommandError, error: error))
        of KillProcess:
          if process == nil:
            let error = "No process to kill."
            messageChan.send(ProcessEvent(kind: CommandError, error: error))
          else:
            process.kill()

      if process != nil:
        line = ""
        # Check process' output streams.
        if process.outputStream.readLine(line):
          messageChan.send(ProcessEvent(kind: ProcessStdout, data: line))
        # Check if the process finished.
        if process.peekExitCode() != -1:
          # First read all the output.
          while true:
            if process.outputStream.readLine(line):
              messageChan.send(ProcessEvent(kind: ProcessStdout, data: line))
            else:
              break
          # Then close the process.
          messageChan.send(
              ProcessEvent(kind: ProcessEnd, code: process.peekExitCode()))
          process.close()
          process = nil
  except:
    let error = "Unhandled exception in thread: " & getCurrentExceptionMsg()
    messageChan.send(ProcessEvent(kind: CommandError, error: error))

proc start*(self: AsyncExecutor) =
  ## Starts the AsyncExecutor's underlying thread.
  createThread[void](self.thread, executorThread)

proc exec*(self: AsyncExecutor,
           command: string, progress: ProgressCB,
           workingDir = "", args: seq[string] = @[],
           env: StringTableRef = nil) {.async.} =
  ## Executes ``command`` asynchronously. Completes returned Future once
  ## the executed command finishes execution.

  # Start the process.
  commandChan.send(
      ThreadCommand(kind: StartProcess, command: command,
                    workingDir: workingDir, args: args, env: env))
  
  # Check every second for messages from the thread.
  while true:
    while true:
      let (received, msg) = messageChan.tryRecv()
      if received:
        case msg.kind
        of ProcessStdout, ProcessStderr, ProcessEnd:
          asyncCheck progress(msg)
          if msg.kind == ProcessEnd: return
        of CommandError:
          raise newException(AsyncExecutorError, msg.error)
      else:
        break
    
    await sleepAsync(1000)

when isMainModule:
  import os
  var executor = newAsyncExecutor()
  executor.start()
  proc onProgress(event: ProcessEvent) {.async.} =
    echo(event.repr)

  waitFor executor.exec(findExe"nim", onProgress, getCurrentDir() / "tests",
                        @["c", "hello.nim"])
