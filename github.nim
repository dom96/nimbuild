import strtabs, sockets, asyncio, scgi, strutils, os, json,
  osproc, streams, times
from cgi import URLDecode
import types

const
  ghRepos = ["https://github.com/Araq/Nimrod"]

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
proc handleConnect(s: PAsyncSocket, userArg: PUserArg) =
  var state = PState(userArg)
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


proc handleModuleMessage(s: PAsyncSocket, userArg: PUserArg) =
  var state = PState(userArg)
  var line = ""
  doAssert state.sock.recvLine(line)
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
  state.sock.userArg = state
  state.sock.handleConnect = handleConnect
  state.sock.handleRead = handleModuleMessage
  state.dispatcher.register(state.sock)
  
  state.platform = "linux-x86"
  state.timeReconnected = -1.0

proc handleRequest(server: var TAsyncScgiState, client: TSocket, 
                   input: string, headers: PStringTable,
                   userArg: PUserArg)
proc open(port: TPort = TPort(5123), scgiPort: TPort = TPort(5000)): PState =
  new(result)
  
  result.dispatcher = newDispatcher()
  
  result.hubPort = port

  result.hubConnect()
  
  # Open scgi stuff
  result.scgi = open(handleRequest, scgiPort, userArg = result)
  result.dispatcher.register(result.scgi)

proc sendBuild(sock: TSocket, payload: PJsonNode) =
  var obj = newJObject()
  obj["payload"] = payload
  sock.send($obj & "\c\L")

# SCGI

proc safeSend(client: TSocket, data: string) =
  try:
    client.send(data)
  except EOS:
    echo("[Warning] Got error from send(): ", OSErrorMsg())

proc handleRequest(server: var TAsyncScgiState, client: TSocket, 
                   input: string, headers: PStringTable,
                   userArg: PUserArg) =
  var state = PState(userArg)
  var hostname = ""
  try:
    hostname = gethostbyaddr(headers["REMOTE_ADDR"]).name
  except EOS:
    hostname = getCurrentExceptionMsg()
  
  echo("Received from IP: ", headers["REMOTE_ADDR"])
  
  if headers["REQUEST_METHOD"] == "POST":
    echo(hostname)
    if hostname.endswith("github.com"):
      if input.startswith("payload="):
        var inp2 = input.copy(8, input.len-1)
        var json = parseJson(URLDecode(inp2))
        if json["repository"]["url"].str in ghRepos:
          sendBuild(state.sock, json)
        else:
          echo("Not our repo. WTF? Got repo url " & json["repository"]["url"].str)
      
      client.safeSend("Status: 202 Accepted\c\L\c\L")
      client.close()
    else:
      echo("Intruder alert! POST detected from an unknown party. Namely: ",
           hostname)
      client.safeSend("Status: 403 Forbidden\c\L\c\L")
      client.close()
  else:
    echo("Received ", headers["REQUEST_METHOD"], " request from ", hostname)
    client.safeSend("Status: 404 Not Found\c\LContent-Type: text/html\c\L\c\L")
    client.safeSend("404 Not Found" & "\c\L")
    client.close()

when isMainModule:
  var state = open()
  while state.dispatcher.poll(-1): nil

