require "./spec_helper"

describe "Transactions" do
  describe "publishes" do
    it "can be commited" do
      with_channel do |ch|
        ch.tx_select
        q = ch.queue
        2.times do |i|
          q.publish "#{i}" * 200_000
        end
        q.get.should be_nil
        ch.tx_commit
        2.times do |i|
          msg = q.get
          if msg
            msg.body_io.to_s.should eq "#{i}" * 200_000
          else
            msg.should_not be_nil
          end
        end
      end
    end

    it "can be rollbacked" do
      with_channel do |ch|
        ch.tx_select
        q = ch.queue
        q.publish ""
        q.get.should be_nil
        ch.tx_rollback
        q.get.should be_nil
        q.message_count.should eq 0
      end
    end
  end

  describe "acks" do
    it "can be commited" do
      with_channel do |ch|
        ch.tx_select
        q = ch.queue
        2.times { |i| q.publish "#{i}" }
        ch.tx_commit
        2.times do |i|
          msg = q.get(no_ack: false).not_nil!
          msg.body_io.to_s.should eq "#{i}"
          msg.ack
        end
        ch.tx_commit
        ch.basic_recover(requeue: true)
        q.message_count.should eq 0
      end
    end

    it "can be rollbacked" do
      with_channel do |ch|
        ch.tx_select
        q = ch.queue
        2.times { |i| q.publish "#{i}" }
        ch.tx_commit
        2.times do |i|
          msg = q.get(no_ack: false).not_nil!
          msg.body_io.to_s.should eq "#{i}"
          msg.ack
        end
        ch.tx_rollback
        ch.basic_recover(requeue: true)
        q.message_count.should eq 2
      end
    end
  end
end
