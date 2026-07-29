# Why you need a buffer, and what a FIFO is

This is the *why* behind `fifo.sv`. It explains the problem the FIFO solves and
what a FIFO does, conceptually. It deliberately says nothing about *how* to build
one — that's the lab.

## 1. The problem: a slow, one-byte-at-a-time link

You already built this link in the I2C lab: the Pi (the controller) and the FPGA
trade **one byte at a time** over a single shared `SDA` wire, and it's **slow** —
clocking one byte across takes on the order of ~15 cycles.

Wire that link straight through, with nothing on the FPGA to hold the bytes, and
the two sides — the Pi and the FPGA, each on its own schedule — trip over each
other:

- **A missed byte.** When a byte arrives, the I2C block raises its `ready` strobe
  for a single moment. If the FPGA is busy and isn't watching at that instant, the
  byte is gone — `ready` pulsed and nothing caught it.
- **Garbage.** There's only one `SDA` line. If both sides drive it at once, or the
  FPGA reads when no real byte is waiting, you read garbage (or the same byte twice).

Both come down to the same thing: the two sides aren't synchronized, and there's
nowhere for a byte to wait.

## 2. The fix: a buffer between the two sides

Put a **holding area** between the I2C side and the other side — a place where
bytes can wait. The producer drops bytes in whenever it has them; the consumer
takes them out whenever it's ready. Neither has to be present at the same
instant. 

But it can't be just *any* pile of bytes. For a stream of characters — text, a
line of input, a message — **order matters**: the bytes must come out in the same
order they went in. A buffer with exactly that property is called a **FIFO**.

## 3. What a FIFO is

**FIFO = First In, First Out.** It's a queue — think of a line at a checkout
counter:

- People **join at the back** and are **served from the front**.
- The first person to join is the first served; the order is preserved. (This is
  the opposite of a stack, or "LIFO," where the *last* one in comes out first —
  like a pile of plates.)
- The line can hold **several people at once**, so the person joining and the
  cashier serving don't have to take turns one at a time.

A FIFO of bytes works the same way:

- You **put** a byte in one end and **take** a byte out the other.
- Bytes come out in the **same order** they went in — that's the whole promise.
- It can hold **several bytes at once**, which is what lets the two sides run
  independently.

A FIFO also has a sense of **how full it is**, and this is what lets each side
know when to wait:

- **Empty** — there's nothing inside, so the taker has nothing to take and must
  wait for the putter.
- **Full** — there's no room left, so the putter must wait for the taker to make
  space. (If something forces a byte in with no room, a byte has to be lost —
  that's an **overflow**, and a well-behaved system is careful never to cause one.)
- Anywhere in between, both sides can keep working.

As long as you respect those two limits — never take from empty, never put into
full — **nothing is lost and nothing is duplicated**. That guarantee is the
entire point of a FIFO.

## 4. Where it fits in this lab

The provided harness already includes a **two-way I2C target** — essentially the
I2C receiver you built in **Lab 3** (Pi = controller, FPGA = target at address
`0x50`), extended so it can also *send* bytes back out. It's written for you and
**already wired to your buffers** — you never touch the I2C side.

Sitting behind that target are **two** of these buffers, one per direction:

- an **rx** buffer — bytes the Pi sends *in*, waiting to be consumed (later: your
  CPU's `getchar`), and
- a **tx** buffer — bytes waiting to go back *out* to the Pi (later: your CPU's
  `print`).

The harness does the putting and taking; **your job (`fifo.sv`) is the buffer
itself.** So the contract is simply: **behave like a queue** — same order out as
in, hold up to its capacity, lose nothing, and report empty/full honestly. Making
that actually happen inside is the lab.

## 5. The ports of `fifo.sv`

Everything above shows up directly in the module you fill in. Here's what each
piece *means* — not how to build it.

**Parameters**

- `WIDTH` — how many bits each item is. Here it's `8` (one byte).
- `DEPTH` — how many items the buffer can hold at once. Here it's `16`.

**Putting a byte in**

- `push` — assert this to add a byte.
- `wdata` — the byte being added (it's the value present when you `push`).
- `full` — high when there is no room. The side doing the putting should look at
  this and wait, rather than push into a full buffer.

**Taking a byte out**

- `pop` — assert this to remove the oldest byte.
- `rdata` — the oldest byte: the one the next `pop` will take.
- `empty` — high when there is nothing inside. The side doing the taking should
  look at this and wait, rather than pop an empty buffer.

**Status**

- `count` — how many bytes are currently held.
- `overflow` — a warning flag: a byte was pushed while the buffer was full, so it
  had to be dropped. It's meant to *stay* set once that happens, so a lost byte
  can be noticed after the fact (in a correct setup it should never trip).
- `clk` — the clock. The FIFO is *synchronous*: it does its work in step with the
  clock, like the rest of the design.
- `rst` — a synchronous, active-high reset. On a clock edge while `rst` is high,
  the FIFO snaps back to **empty** (count 0) and forgets everything it was
  holding (including a tripped `overflow`). On the board it's wired to button 0,
  so a press clears the buffers; the rest of the time it stays low and the FIFO
  just runs normally.

That's the whole contract. The header of `fifo.sv` states it precisely (for
example, exactly when `rdata` is valid); this page is just the meaning behind
each signal.
