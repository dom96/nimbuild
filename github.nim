import strtabs, sockets, scgi, strutils, os, json, osproc, streams
from cgi import URLDecode
import types

const
  ghRepos = ["https://github.com/Araq/Nimrod"]

type
  TState = object
    sock: TSocket
    scgi: TScgiState
    platform: string
    
# Communication

proc parseReply(line: string, expect: string): Bool =
  var jsonDoc = parseJson(line)
  return jsonDoc["reply"].str == expect

proc open(port: TPort = TPort(5123), scgiPort: TPort = TPort(5000)): TState =
  result.sock = socket()
  result.sock.connect("127.0.0.1", port)
  result.platform = "linux-x86"
  
  # Send greeting
  var obj = newJObject()
  obj["name"] = newJString("github")
  obj["platform"] = newJString(result.platform)
  result.sock.send($obj & "\c\L")
  # Wait for reply.
  var readSocks = @[result.sock]
  if select(readSocks, 1500) == 1 and readSocks.len == 0:
    var line = ""
    assert result.sock.recvLine(line)
    assert parseReply(line, "OK")
    echo("The hub accepted me!")
  else:
    raise newException(EInvalidValue, 
                       "Hub didn't accept me. Waited 1.5 seconds.")
  
  # Open scgi stuff
  open(result.scgi, scgiPort)

proc handleMessage(state: TState, line: string) =
  echo("Got message from hub: ", line)

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

proc handleRequest(state: var TState) =
  var client = state.scgi.client
  var input = state.scgi.input
  var headers = state.scgi.headers
  
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
  var readSock: seq[TSocket] = @[]
  while True:
    readSock = @[state.sock]
    if state.scgi.next(200):
      handleRequest(state)
    
    if select(readSock, 10) == 1 and readSock.len == 0:
      var line = ""
      if state.sock.recvLine(line):
        state.handleMessage(line)
      else:
        # TODO: Try reconnecting.
        OSError()
    
    #state.checkProgress()
    
    
