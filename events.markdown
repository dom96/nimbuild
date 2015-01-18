# Events

## connected

Sent by clients to the hub when they connect. This is the first message that
is sent by the client.

**Args:**

* **name** - Name of the client or rather it's type.
* **guid** - A unique identifier to identify the client.

## accepted

Sent by the hub to the clients when a client has been accepted.

**Args:**

*Same as ``connected`` event.*

## ping

Sent by hub to clients to ensure they are still connected. The client should
immediately reply with a ``pong`` message.

**Args:**

* **time** - Time since unix epoch in seconds as a float.

## pong

Sent in reply to a ``ping`` message.

**Args:**

*Same as ``pong`` event*
