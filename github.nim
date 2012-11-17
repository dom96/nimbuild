import strtabs, sockets, asyncio, scgi, strutils, os, json,
  osproc, streams, times
from cgi import URLDecode
import jester
import types

type
  PState = ref TState
  TState = object of TObject
    dispatcher: PDispatcher
    sock: PAsyncSocket
    scgi: PAsyncScgiState
    platform: string

    hubPort: TPort

    timeReconnected: float

# Communication

proc parseReply(line: string, expect: string): Bool =
  var jsonDoc = parseJson(line)
  return jsonDoc["reply"].str == expect

proc hubConnect(state: PState)
proc handleConnect(s: PAsyncSocket, state: PState) =
  try:
    # Send greeting
    var obj = newJObject()
    obj["name"] = newJString("github")
    obj["platform"] = newJString(state.platform)
    state.sock.send($obj & "\c\L")
    # Wait for reply.
    var line = ""
    sleep(1500)
    if state.sock.recvLine(line):
      assert(line != "")
      doAssert parseReply(line, "OK")
      echo("The hub accepted me!")
    else:
      raise newException(EInvalidValue,
                         "Hub didn't accept me. Waited 1.5 seconds.")
  except EOS:
    echo(getCurrentExceptionMsg())
    s.close()
    echo("Waiting 5 seconds.")
    sleep(5000)
    state.hubConnect()

proc handleMessage(state: PState, line: string) =
  echo("Got message from hub: ", line)

proc handleModuleMessage(s: PAsyncSocket, state: PState) =
  var line = ""
  if not state.sock.recvLine(line):
    echo(OSErrorMsg())
  if line != "":
    state.handleMessage(line)
  else:
    state.sock.close()
    echo("Disconnected from hub: ", OSErrorMsg())
    echo("Reconnecting...")
    state.hubConnect()

proc hubConnect(state: PState) =
  state.sock = AsyncSocket()
  state.sock.connect("127.0.0.1", state.hubPort)
  state.sock.handleConnect = proc (s: PAsyncSocket) = handleConnect(s, state)
  state.sock.handleRead = proc (s: PAsyncSocket) = handleModuleMessage(s, state)
  state.dispatcher.register(state.sock)
  
  state.platform = "linux-x86"
  state.timeReconnected = -1.0

proc open(port: TPort = TPort(5123), scgiPort: TPort = TPort(5000)): PState =
  var cres: PState
  new(cres)
  
  cres.dispatcher = newDispatcher()
  
  cres.hubPort = port

  cres.hubConnect()
  
  # jester
  cres.dispatcher.register(port = scgiPort, http = false)
  result = cres

proc sendBuild(sock: TSocket, payload: PJsonNode) =
  var obj = newJObject()
  obj["payload"] = payload
  sock.send($obj & "\c\L")


when isMainModule:
  var state = open()
  
  post "/":
    echo("[POST] ", request.ip)
    var hostname = ""
    try:
      hostname = getHostByAddr(request.ip).name
    except:
      hostname = getCurrentExceptionMsg()
    echo("       ", hostname)
    cond hostname.endswith("github.com")
    let payload = @"payload"
    var json = parseJSON(payload)
    sendBuild(state.sock, json)
    echo("       ", json["after"].str)
  
  while state.dispatcher.poll(-1): nil

