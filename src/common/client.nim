import asyncdispatch, asyncnet, future, logging, json

import messages

## Abstracts communicates with the Hub away.

type
  ClientObj = object
    socket: AsyncSocket
    name: string
    onMessage: (Client, JsonNode) -> Future[void]
    address: string
    port: Port
  Client = ref ClientObj # TODO: Workaround for compiler crash.

proc newClient*(name: string,
                onMessage: (Client, JsonNode) -> Future[void]): Client =
  new result
  result.socket = newAsyncSocket()
  result.name = name
  result.onMessage = onMessage

proc connect*(client: Client, address: string, port = 5123.Port): Future[void]

proc reconnect*(client: Client) {.async.} =
  while true:
    let connectFut = client.connect(client.address, client.port)
    await connectFut
    if connectFut.failed:
      error("Couldn't reconnect to hub. Waiting 5 seconds.")
      await sleepAsync(5000)
    else:
      break

proc connect*(client: Client, address: string, port = 5123.Port) {.async.} =
  ## Connect once. Won't attempt reconnecting if it can't connect on first
  ## attempt.
  await client.socket.connect(address, port)
  client.address = address
  client.port = port

  await client.socket.send(genMessage("connected", %{"name": %client.name}))

  while true:
    let line = client.socket.recvLine()
    if line == "":
      error("Disconnected from hub.")
      await reconnect(client)
      return

    let message = parseMessage(line)
    if message.kind == JNull:
      warn("Invalid message received from Hub: " & line)
      continue

    info(line)
    asyncCheck client.onMessage(client, message)

proc start*(client: Client, address: string, port = 5123.Port) {.async.} =
  ## Starts the attempts for connection.
  client.address = address
  client.port = port
  reconnect(client)
