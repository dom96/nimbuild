import asyncdispatch, asyncnet, future, logging, json, oids

import messages

## Abstracts communicates with the Hub away.

type
  ClientObj = object
    socket: AsyncSocket
    name: string
    onMessage: (Client, JsonNode) -> Future[void]
    address: string
    port: Port
    guid: string
  Client* = ref ClientObj # TODO: Workaround for compiler crash.

proc newClient*(name: string,
                onMessage: (Client, JsonNode) -> Future[void]): Client =
  new result
  result.socket = newAsyncSocket()
  result.name = name
  result.onMessage = onMessage

proc send*(client: Client, event: string, args: JsonNode): Future[void] =
  client.socket.send(genMessage(event, args))

proc connect*(client: Client, address: string, port = 5123.Port): Future[void]

proc reconnect*(client: Client) {.async.} =
  while true:
    client.socket = newAsyncSocket()
    let connectFut = client.connect(client.address, client.port)
    await connectFut
    if connectFut.failed:
      client.socket.close()
      error("Couldn't reconnect to hub: " & connectFut.readError.msg)
      info("Waiting 5 seconds")
      await sleepAsync(5000)
    else:
      break

proc connect*(client: Client, address: string, port = 5123.Port): Future[void] =
  ## Connect once. Won't attempt reconnecting if it can't connect on first
  ## attempt.

  proc connectFoo() {.async.} = # TODO: Bug #1970
    await client.socket.connect(address, port)
    client.address = address
    client.port = port
    client.guid = $genOid()

    await client.socket.send(genMessage("connected",
      %{"name": %client.name, "guid": %client.guid}))

    info("Connected to hub.")
    while true:
      let line = await client.socket.recvLine()
      if line == "":
        error("Disconnected from hub.")
        client.socket.close()
        await reconnect(client)
        return

      let message = parseMessage(line)
      if message.kind == JNull:
        error("Invalid message received from Hub: " & line)
        continue

      var propagate = true
      case message{"event"}.getStr()
      of "ping":
        await client.socket.send(
          genMessage("pong", %{"time": %message{"args"}{"time"}.getFloat()}))
        propagate = false
      else: discard

      info("Received: " & line)
      if propagate:
        asyncCheck client.onMessage(client, message)
  return connectFoo()

proc start*(client: Client, address: string, port = 5123.Port): Future[void] =
  ## Starts the attempts for connection.
  client.address = address
  client.port = port
  result = reconnect(client)
