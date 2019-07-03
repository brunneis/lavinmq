[![Build Status](https://travis-ci.com/84codes/avalanchemq.svg?token=rfwynuMNGnX9tuyspVud&branch=master)](https://travis-ci.com/84codes/avalanchemq)
[![Download](https://api.bintray.com/packages/84codes/debian/avalanchemq/images/download.svg)](https://bintray.com/84codes/debian/avalanchemq/_latestVersion)

# ![AvalancheMQ](static/img/logo-avalanche-mq-black.png)

A message queue server that implements the AMQP 0-9-1 protocol.
Written in [Crystal](https://crystal-lang.org/).

Aims to be very fast, have low RAM requirements, handle extremely long queues,
many connections and require minimal configuration.

## Implementation

AvalancheMQ is written in [Crystal](https://crystal-lang.org/), a modern
language built on the LLVM, that has a Ruby-like syntax, uses an event loop
library for IO, is garbage collected, adopts a CSP-like [concurrency
model](https://crystal-lang.org/docs/guides/concurrency.html) and compiles down
to a single binary. You can liken it to Go, but with a nicer syntax.

Instead of trying to cache message in RAM we write all messages as fast as we can to
disk and let the OS cache do the caching.

Each vhost is backed by a message store on disk, it's just a series of files (segments),
that can grow to 256 MB each. Each incoming message is appended to the last segment,
prefixed with a timestamp, its exchange name, routing key and message headers.
If the message is routed to a queue then the segment number and the position in
that segment is written to each queue's queue index. The queue index is
just an [in-memory array](https://crystal-lang.org/api/Deque.html)
of segment numbers and file positions. In the case of durable queues
the message index is also appended to a file.

When a message is being consumed it removes the segment-position from the queue's
in-memory array, and write the segment-position to an "ack" file. That way
we can restore the queue index on boot by reading all the segment-position stored
in the queue index file, then exclude all the segment-position read from the
"ack" file.  The queue index is rewritten when the "ack" file becomes 16 MB,
that is, every 16 \* 1024 \* 1024 / 8 = 2097152 message.
Then the current in-memory queue index is written to a new file and the
"ack" file is truncated.

Segments in the vhost's message store are being deleted when no queue index as
a reference to a position in that segment.

Declarations of queues, exchanges and bindings are written to a definitions
file (if the target is durable), encoded as the AMQP frame they came in as.
Periodically this file is garbage collected
by writing only the current in-memory state to the file (getting rid
of all delete events). This file is read on boot to restore all definitions.

All non-AMQP objects like users, vhosts, policies, etc. are stored in
JSON files. Most often these type of objects does not have a high
turnover rate, so we believe that JSON in this case makes it easy for
operators to modify things when the server is not running, if ever needed.

In the data directory we store `users.json` and `vhosts.json` as mentioned earlier,
and each vhost has a directory in which we store `definitions.amqp`
(encoded as AMQP frames), `policies.json` and the messages named such as `msgs.0000000124`.
Each vhost directory is named after the sha1 hash of its real name. The same goes
for the queue directories in the vhost directory. The queue directories only has two files,
`ack` and `enq`, also described earlier.

## Features

* AMQP 0-9-1 compatible
* AMQPS (TLS)
* Publisher confirm
* Policies
* Shovels
* HTTP API
* Queue federation
* Dead-lettering
* TTL support on queue, message, and policy level
* CC/BCC
* Alternative exchange
* Exchange to exchange bindings
* Direct-reply-to RPC
* Users and ACL rules
* VHost separation
* Consumer cancellation
* Queue max-length
* Importing/export definitions

Currently missing features

* WebSockets
* Exchange federation
* Clustering
* Plugins
* Priority queues
* Delayed exchanges
* Transactions (probably won't implement)

Wish list

* Rewindable queues (all messages that are published to an exchange
  are stored and can be dumped into a queue when a certain binding is
  made, even if they have already been consumed before)
* Horizontal scaling
* Built-in stream processor engine

## Performance

A single m5.large EC2 instance, with a 500 GB GP2 EBS drive (XFS formatted),
can sustain about 150.000 messages/s (1KB each, single queue, single producer,
single consumer). When the message size is 1MB the instance's network speed
becomes the bottleneck at 10 Gbit/s. When the OS disk cache is full
the EBS performance becomes the bottleneck, at about 250 MB/s.

Enqueueing 10 million messages only uses 80MB RAM. 8000
connection uses only about 400 MB RAM. Declaring 100.000 queues uses about 100
MB RAM. About 20.000 bindings per second can be made to both durable and
non-durable queues.

## Installation

In Debian/Ubuntu:

```bash
sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 379CE192D401AB61
echo "deb https://dl.bintray.com/84codes/debian $(lsb_release -cs) avalanchemq" | sudo tee /etc/apt/sources.list.d/avalanchemq.list
sudo apt update
sudo apt install avalanchemq
```

In CentOS/Redhat/Amazon Linux:

```bash
sudo tee /etc/yum.repos.d/avalanchemq.repo << EOF
[avalanchemq]
name=avalanchemq
baseurl=https://dl.bintray.com/84codes/rpm
gpgcheck=0
repo_gpgcheck=0
enabled=1
EOF
sudo yum install avalanchemq
sudo systemctl start avalanchemq
```

From source:

```bash
git clone git@github.com:avalanchemq/avalanchemq.git
cd avalanchemq
shards build --release --production
install bin/avalanchemq /usr/local/bin/avalanchemq
```

Refer to
[Crystal's installation documentation](https://crystal-lang.org/docs/installation/)
on how to install Crystal.

## Usage

AvalancheMQ only requires one argument, and it's a path to a data directory:

`avalanchemq -D /var/lib/avalanchemq`

More configuration options can be viewed with `-h`,
and you can specify a configration file too, see [extras/config.ini](extras/config.ini)
for an example.

## OS configuration

If you have a lot of clients that open connections
at the same time, eg. after a restart, you may see
"kernel: Possible SYN flooding on port 5671" in the syslog.
Then you probably should increase `net.ipv4.tcp_max_syn_backlog`:

```bash
sysctl -w net.ipv4.tcp_max_syn_backlog=2048 # default 512
```

## Debugging

In Linux `perf` is the tool of choice when tracing and measuring performance.

To see which syscalls that are made use:
```
sudo perf trace -p $(ps -C avalanchemq -o pid=)
```

To get a live analysis of the mostly called functions, run:

```bash
sudo perf top -p $(ps -C avalanchemq -o pid=)
```

A more [detailed tutorial on `perf` is available here](https://perf.wiki.kernel.org/index.php/Tutorial).

In OS X the app [`Instruments` that's bundled with Xcode can be used for tracing](https://help.apple.com/instruments/mac/current/).

## Contributing

Fork, create feature branch, submit pull request.

### Develop

1. Run specs with `crystal spec`
1. Compile and run locally with `crystal run src/avalanchemq.cr -- -D /tmp/amqp`
1. Build with `shards build`

### Release

1. Update `CHANGELOG.md`
1. Bump version in `shards.yml` & `src/avalanchemq/version.cr`
1. Create and push tag
1. `build/debian 1 && build/bintray-push 1`

## Contributors

* [Carl Hörberg](carl@84codes.com)
* [Anders Bälter](anders@84codes.com)

## License

The software is licensed under the [Apache License 2.0](LICENSE).

Copyright 2018-2019 84codes AB

AvalancheMQ is a trademark of 84codes AB
