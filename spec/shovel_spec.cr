require "./spec_helper"
require "../src/lavinmq/shovel"
require "http/server"

module ShovelSpecHelpers
  def self.setup_qs(ch, prefix = "") : {AMQP::Client::Exchange, AMQP::Client::Queue}
    x = ch.exchange("", "direct", passive: true)
    ch.queue("#{prefix}q1")
    q2 = ch.queue("#{prefix}q2")
    {x, q2}
  end
end

describe LavinMQ::Shovel do
  describe "AMQP" do
    vhost = Server.vhosts.create("x")

    it "should shovel and stop when queue length is met" do
      source = LavinMQ::Shovel::AMQPSource.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "ql_q1",
        delete_after: LavinMQ::Shovel::DeleteAfter::QueueLength,
        direct_user: Server.users.direct_user
      )
      dest = LavinMQ::Shovel::AMQPDestination.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "ql_q2",
        delete_after: LavinMQ::Shovel::DeleteAfter::QueueLength,
        direct_user: Server.users.direct_user
      )
      shovel = LavinMQ::Shovel::Runner.new(source, dest, "ql_shovel", vhost)
      with_channel do |ch|
        x, q2 = ShovelSpecHelpers.setup_qs ch, "ql_"
        x.publish_confirm "shovel me 1", "ql_q1"
        x.publish_confirm "shovel me 2", "ql_q1"
        shovel.run
        x.publish_confirm "shovel me 3", "ql_q1"
        q2.get(no_ack: true).try(&.body_io.to_s).should eq "shovel me 1"
        q2.get(no_ack: true).try(&.body_io.to_s).should eq "shovel me 2"
        q2.get(no_ack: true).try(&.body_io.to_s).should be_nil
        Server.vhosts["/"].shovels.empty?.should be_true
      end
    end

    it "should shovel large messages" do
      source = LavinMQ::Shovel::AMQPSource.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "lm_q1",
        delete_after: LavinMQ::Shovel::DeleteAfter::QueueLength,
        direct_user: Server.users.direct_user
      )
      dest = LavinMQ::Shovel::AMQPDestination.new("spec", URI.parse(AMQP_BASE_URL), "lm_q2", direct_user: Server.users.direct_user)
      shovel = LavinMQ::Shovel::Runner.new(source, dest, "lm_shovel", vhost)
      with_channel do |ch|
        x, q2 = ShovelSpecHelpers.setup_qs ch, "lm_"
        x.publish_confirm "a" * 200_000, "lm_q1"
        shovel.run
        sleep 10.milliseconds
        q2.get(no_ack: true).not_nil!.body_io.to_s.bytesize.should eq 200_000
      end
    end

    it "should shovel forever" do
      source = LavinMQ::Shovel::AMQPSource.new("spec", URI.parse(AMQP_BASE_URL), "sf_q1", direct_user: Server.users.direct_user)
      dest = LavinMQ::Shovel::AMQPDestination.new("spec", URI.parse(AMQP_BASE_URL), "sf_q2", direct_user: Server.users.direct_user)
      shovel = LavinMQ::Shovel::Runner.new(source, dest, "sf_shovel", vhost)
      with_channel do |ch|
        x, q2 = ShovelSpecHelpers.setup_qs ch, "sf_"
        x.publish_confirm "shovel me 1", "sf_q1"
        x.publish_confirm "shovel me 2", "sf_q1"
        spawn shovel.run
        msgs = Channel(String).new
        q2.subscribe(no_ack: true) do |msg|
          msgs.send(msg.body_io.to_s)
        end
        wait_for { shovel.running? }
        x.publish_confirm "shovel me 3", "sf_q1"
        3.times do |i|
          msgs.receive.should eq "shovel me #{i + 1}"
        end
        shovel.running?.should be_true
      end
    end

    it "should shovel with ack mode on-publish" do
      ack_mode = LavinMQ::Shovel::AckMode::OnPublish
      source = LavinMQ::Shovel::AMQPSource.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "ap_q1",
        prefetch: 1_u16,
        ack_mode: ack_mode,
        direct_user: Server.users.direct_user
      )
      dest = LavinMQ::Shovel::AMQPDestination.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "ap_q2",
        ack_mode: ack_mode,
        direct_user: Server.users.direct_user
      )
      shovel = LavinMQ::Shovel::Runner.new(source, dest, "ap_shovel", vhost)
      with_channel do |ch|
        x, q2 = ShovelSpecHelpers.setup_qs ch, "ap_"
        x.publish_confirm "shovel me", "ap_q1"
        spawn shovel.run
        wait_for { shovel.running? }
        sleep 0.1 # Give time for message to be shoveled
        Server.vhosts["/"].queues["ap_q1"].message_count.should eq 0
        q2.get(no_ack: false).try(&.body_io.to_s).should eq "shovel me"
      end
    end

    it "should shovel with ack mode no-ack" do
      ack_mode = LavinMQ::Shovel::AckMode::NoAck
      source = LavinMQ::Shovel::AMQPSource.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "na_q1",
        ack_mode: ack_mode,
        direct_user: Server.users.direct_user
      )
      dest = LavinMQ::Shovel::AMQPDestination.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "na_q2",
        ack_mode: ack_mode,
        direct_user: Server.users.direct_user
      )
      shovel = LavinMQ::Shovel::Runner.new(source, dest, "na_shovel", vhost)
      with_channel do |ch|
        x, q2 = ShovelSpecHelpers.setup_qs ch, "na_"
        x.publish_confirm "shovel me", "na_q1"
        spawn { shovel.run }
        wait_for { shovel.running? }
        sleep 0.1 # Give time for message to be shoveled
        Server.vhosts["/"].queues["na_q1"].message_count.should eq 0
        q2.get(no_ack: false).try(&.body_io.to_s).should eq "shovel me"
      end
    end

    it "should shovel past prefetch" do
      source = LavinMQ::Shovel::AMQPSource.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "prefetch_q1",
        delete_after: LavinMQ::Shovel::DeleteAfter::QueueLength,
        prefetch: 21_u16,
        direct_user: Server.users.direct_user
      )
      dest = LavinMQ::Shovel::AMQPDestination.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "prefetch_q2",
        delete_after: LavinMQ::Shovel::DeleteAfter::QueueLength,
        prefetch: 21_u16,
        direct_user: Server.users.direct_user
      )
      shovel = LavinMQ::Shovel::Runner.new(source, dest, "prefetch_shovel", vhost)
      with_channel do |ch|
        x = ShovelSpecHelpers.setup_qs(ch, "prefetch_").first
        100.times do
          x.publish_confirm "shovel me", "prefetch_q1"
        end
        wait_for { Server.vhosts["/"].queues["prefetch_q1"].message_count == 100 }
        shovel.run
        wait_for { shovel.terminated? }
        Server.vhosts["/"].queues["prefetch_q1"].message_count.should eq 0
        Server.vhosts["/"].queues["prefetch_q2"].message_count.should eq 100
      end
    end

    it "should shovel once qs are declared" do
      source = LavinMQ::Shovel::AMQPSource.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "od_q1",
        direct_user: Server.users.direct_user
      )
      dest = LavinMQ::Shovel::AMQPDestination.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "od_q2",
        direct_user: Server.users.direct_user
      )
      shovel = LavinMQ::Shovel::Runner.new(source, dest, "od_shovel", vhost)
      with_channel do |ch|
        spawn { shovel.run }
        x, q2 = ShovelSpecHelpers.setup_qs ch, "od_"
        x.publish_confirm "shovel me", "od_q1"
        rmsg = nil
        wait_for { rmsg = q2.get(no_ack: true) }
        rmsg.not_nil!.body_io.to_s.should eq "shovel me"
      end
    end

    it "should reconnect and continue" do
      with_channel do |ch|
        q1 = ch.queue("rc_q1")
        _q2 = ch.queue("rc_q2")
        q1.publish_confirm "shovel me 1", props: AMQ::Protocol::Properties.new(delivery_mode: 2_u8)
      end
      config = %({
        "src-uri": "#{AMQP_BASE_URL}",
        "src-queue": "rc_q1",
        "dest-uri": "#{AMQP_BASE_URL}",
        "dest-queue": "rc_q2",
        "src-prefetch-count": 2})
      p = LavinMQ::Parameter.new("shovel", "rc_shovel", JSON.parse(config))
      Server.vhosts["/"].add_parameter(p)
      Server.restart
      wait_for { Server.vhosts["/"].shovels.size > 0 }
      shovel = Server.vhosts["/"].shovels["rc_shovel"]
      wait_for { shovel.running? }
      with_channel do |ch|
        q1 = ch.queue("rc_q1", durable: true)
        q2 = ch.queue("rc_q2", durable: true)
        msgs = Channel(String).new
        q2.subscribe(no_ack: true) do |msg|
          msgs.send(msg.body_io.to_s)
        end
        props = AMQ::Protocol::Properties.new(delivery_mode: 2_u8)
        spawn do
          q1.publish_confirm "shovel me 2", props: props
          q1.publish_confirm "shovel me 3", props: props
          q1.publish_confirm "shovel me 4", props: props
        end
        4.times do |i|
          msgs.receive.should eq "shovel me #{i + 1}"
        end
        ch.queue_declare("rc_q1", passive: true)[:message_count].should eq 0
      end
    end

    it "should shovel over amqps" do
      source = LavinMQ::Shovel::AMQPSource.new(
        "spec",
        URI.parse("#{AMQPS_BASE_URL}?verify=none"),
        "ssl_q1",
        direct_user: Server.users.direct_user
      )
      dest = LavinMQ::Shovel::AMQPDestination.new(
        "spec",
        URI.parse("#{AMQPS_BASE_URL}?verify=none"),
        "ssl_q2",
        direct_user: Server.users.direct_user
      )
      shovel = LavinMQ::Shovel::Runner.new(source, dest, "ssl_shovel", vhost)
      with_channel do |ch|
        x, q2 = ShovelSpecHelpers.setup_qs ch, "ssl_"
        spawn { shovel.run }
        x.publish_confirm "shovel me", "ssl_q1"
        msgs = Channel(AMQP::Client::DeliverMessage).new
        q2.subscribe { |m| msgs.send m }
        msg = msgs.receive
        msg.body_io.to_s.should eq "shovel me"
      end
    end

    it "should ack all messages that has been moved" do
      prefetch = 9_u16
      source = LavinMQ::Shovel::AMQPSource.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "prefetch2_q1",
        prefetch: prefetch,
        direct_user: Server.users.direct_user
      )
      dest = LavinMQ::Shovel::AMQPDestination.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "prefetch2_q2",
        prefetch: prefetch,
        direct_user: Server.users.direct_user
      )
      shovel = LavinMQ::Shovel::Runner.new(source, dest, "prefetch2_shovel", vhost)
      with_channel do |ch|
        x = ShovelSpecHelpers.setup_qs(ch, "prefetch2_").first
        spawn { shovel.run }
        x.publish_confirm "shovel me 1", "prefetch2_q1"
        x.publish_confirm "shovel me 2", "prefetch2_q1"
        x.publish_confirm "shovel me 2", "prefetch2_q1"
        x.publish_confirm "shovel me 2", "prefetch2_q1"
        wait_for { Server.vhosts["/"].queues["prefetch2_q2"].message_count == 4 }
        sleep 0.1
        shovel.terminate
        Server.vhosts["/"].queues["prefetch2_q2"].message_count.should eq 4
        Server.vhosts["/"].queues["prefetch2_q1"].message_count.should eq 0
      end
    end

    describe "authentication error" do
      it "should be stopped" do
        uri = URI.parse(AMQP_BASE_URL)
        uri.user = "foo"
        uri.password = "bar"
        source = LavinMQ::Shovel::AMQPSource.new(
          "spec",
          uri,
          "q1",
          direct_user: Server.users.direct_user
        )
        dest = LavinMQ::Shovel::AMQPDestination.new(
          "spec",
          uri,
          "q2",
          direct_user: Server.users.direct_user
        )
        shovel = LavinMQ::Shovel::Runner.new(source, dest, "auth_fail", vhost)
        spawn { shovel.run }
        wait_for { shovel.details_tuple[:error] }
        shovel.details_tuple[:error].not_nil!.should contain "ACCESS_REFUSED"
        shovel.terminate
        shovel.state.should eq "Terminated"
      end
    end

    it "should count messages shoveled" do
      source = LavinMQ::Shovel::AMQPSource.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "c_q1",
        direct_user: Server.users.direct_user
      )
      dest = LavinMQ::Shovel::AMQPDestination.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "c_q2",
        direct_user: Server.users.direct_user
      )
      shovel = LavinMQ::Shovel::Runner.new(source, dest, "c_shovel", vhost)
      with_channel do |ch|
        x, _ = ShovelSpecHelpers.setup_qs ch, "c_"
        spawn { shovel.run }
        10.times do
          x.publish_confirm "shovel me", "c_q1"
        end
        wait_for { Server.vhosts["/"].queues["c_q2"].message_count == 10 }
        shovel.details_tuple[:message_count].should eq 10
      end
      shovel.state.should eq "Running"
    end
  end

  describe "HTTP" do
    it "should shovel" do
      # # Setup HTTP server
      h = Hash(String, String).new
      body = "<no body>"
      path = "<no path>"
      server = HTTP::Server.new do |context|
        context.request.headers.each do |k, v|
          h[k] = v.first
        end
        body = context.request.body.try &.gets
        path = context.request.path
        context.response.content_type = "text/plain"
        context.response.print "ok"
        context
      end
      addr = server.bind_unused_port
      spawn server.listen

      vhost = Server.vhosts.create("x")
      # # Setup shovel source and destination
      source = LavinMQ::Shovel::AMQPSource.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "ql_q1",
        delete_after: LavinMQ::Shovel::DeleteAfter::QueueLength,
        direct_user: Server.users.direct_user
      )
      dest = LavinMQ::Shovel::HTTPDestination.new(
        "spec",
        URI.parse("http://a:b@#{addr}/pp")
      )

      shovel = LavinMQ::Shovel::Runner.new(source, dest, "ql_shovel", vhost)
      with_channel do |ch|
        x, _ = ShovelSpecHelpers.setup_qs ch, "ql_"
        headers = AMQP::Client::Arguments.new
        headers["a"] = "b"
        props = AMQP::Client::Properties.new("text/plain", nil, headers)
        x.publish_confirm "shovel me", "ql_q1", props: props
        shovel.run
        sleep 0.01

        # Check that we have sent one message successfully
        path.should eq "/pp"
        h["User-Agent"].should eq "LavinMQ"
        h["Content-Type"].should eq "text/plain"
        h["Authorization"].should eq "Basic YTpi" # base64 encoded "a:b"
        h["X-a"].should eq "b"
        body.should eq "shovel me"

        Server.vhosts["/"].shovels.empty?.should be_true
      end
    end

    it "should set path for URI from headers" do
      # # Setup HTTP server
      path = "<no path>"
      server = HTTP::Server.new do |context|
        path = context.request.path
        context.response.content_type = "text/plain"
        context.response.print "ok"
        context
      end
      addr = server.bind_unused_port
      spawn server.listen

      vhost = Server.vhosts.create("x")
      # # Setup shovel source and destination
      source = LavinMQ::Shovel::AMQPSource.new(
        "spec",
        URI.parse(AMQP_BASE_URL),
        "ql_q1",
        delete_after: LavinMQ::Shovel::DeleteAfter::QueueLength,
        direct_user: Server.users.direct_user
      )
      dest = LavinMQ::Shovel::HTTPDestination.new(
        "spec",
        URI.parse("http://a:b@#{addr}")
      )

      shovel = LavinMQ::Shovel::Runner.new(source, dest, "ql_shovel", vhost)
      with_channel do |ch|
        x, _ = ShovelSpecHelpers.setup_qs ch, "ql_"
        headers = AMQP::Client::Arguments.new
        headers["uri_path"] = "/some_path"
        props = AMQP::Client::Properties.new("text/plain", nil, headers)
        x.publish_confirm "shovel me", "ql_q1", props: props
        shovel.run
        sleep 10.milliseconds # better when than sleep?
        path.should eq "/some_path"
      end
    end
  end
end
