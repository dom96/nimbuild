import strtabs, sockets, asyncio, scgi, strutils, os, json,
  osproc, streams, times, parseopt
  
from cgi import URLDecode
from httpclient import get # httpclient.post conflicts with jester.post
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
    scgiPort: TPort

    timeReconnected: float

    hookIPs: seq[string]

when not defined(ssl):
  {.error: "Need SSL support to get Github's IPs, compile with -d:ssl.".}

# Command line reading
proc getCommandArgs(state: PState) =
  for kind, key, value in getOpt():
    case kind
    of cmdArgument:
      quit("Syntax: ./github -hp hubPort -sp scgiPort")
    of cmdLongOption, cmdShortOption:
      if value == "":
        quit("Syntax: ./github -hp hubPort -sp scgiPort")
      case key
      of "hubPort", "hp":
        state.hubPort = TPort(parseInt(value))
      of "scgiPort", "sp":
        state.scgiPort = TPort(parseInt(value))
      else: quit("Syntax: ./github -hp hubPort -sp scgiPort")
    of cmdEnd: assert false

# Github specific

proc getHookIPs(hookIPs: var seq[string], timeout = 3000) =
  ## Gets the allowed IP addresses using Github's API.
  except: echo("  [Warning] Getting hookIPs failed: ", getCurrentExceptionMsg())
  let resp = get("https://api.github.com/meta")
  if resp.status[0] in {'4', '5'}:
    echo("  [Warning] HookIPs won't change. Status code was: ", resp.status)
    return
  
  let j = parseJSON(resp.body)
  if j.existsKey("hooks"):
    for ip in j["hooks"]:
      if ip.str.endsWith("/32"):
        hookIPs.add(ip.str[0 .. -4])

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
    obj["version"] = %"1"
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
  new(result)
  
  result.dispatcher = newDispatcher()
  
  result.hubPort = port
  result.scgiPort = scgiPort
  result.hookIPs = @[]
  
  result.getCommandArgs()

  result.hubConnect()
  
  # jester
  result.dispatcher.register(port = result.scgiPort, http = false)

  getHookIPs(result.hookIPs, timeout = -1) # Get initial set of IPs

proc sendBuild(sock: TSocket, payload: PJsonNode) =
  var obj = newJObject()
  obj["payload"] = payload
  sock.send($obj & "\c\L")

proc isAuthorized(hookIPs: var seq[String], ip: string): bool =
  getHookIPs(hookIPs)
  return ip in hookIPs

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
    let authorized = state.hookIPs.isAuthorized(request.ip)
    echo("       ", if authorized: "Authorized." else: "Denied.")
    cond authorized
    let payload = @"payload"
    var json = parseJSON(payload)
    sendBuild(state.sock, json)
    echo("       ", json["after"].str)
    resp "Cheers, Github."
  
  while state.dispatcher.poll(-1): nil

