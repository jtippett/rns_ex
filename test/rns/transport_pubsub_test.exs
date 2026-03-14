defmodule RNS.Transport.PubSubTest do
  use ExUnit.Case, async: false

  setup do
    RNS.Test.SupervisedHelpers.clear_transport_tables()
    RNS.Test.SupervisedHelpers.clear_identity_store_tables()

    on_exit(fn ->
      RNS.Transport.unsubscribe(:announces)
    end)

    :ok
  end

  describe "subscribe/unsubscribe" do
    test "subscribe/1 subscribes calling process to event topic" do
      :ok = RNS.Transport.subscribe(:announces)
      assert Registry.lookup(RNS.Transport.Registry, :announces) != []
    end

    test "unsubscribe/1 removes calling process subscription" do
      :ok = RNS.Transport.subscribe(:announces)
      :ok = RNS.Transport.unsubscribe(:announces)
      assert Registry.lookup(RNS.Transport.Registry, :announces) == []
    end

    test "subscribe with invalid topic returns error" do
      assert {:error, :invalid_topic} = RNS.Transport.subscribe(:bogus)
    end

    test "subscribe is idempotent (calling twice does not crash)" do
      :ok = RNS.Transport.subscribe(:announces)
      :ok = RNS.Transport.subscribe(:announces)
      assert Registry.lookup(RNS.Transport.Registry, :announces) != []
    end
  end

  describe "announce notifications" do
    test "subscriber receives :rns_announce message with Announce struct" do
      :ok = RNS.Transport.subscribe(:announces)

      dest_hash = :crypto.strong_rand_bytes(16)
      identity = RNS.Identity.new()
      app_data = "test_data"
      name_hash = :crypto.strong_rand_bytes(10)

      RNS.Transport.notify_subscribers(:announces, {dest_hash, identity, app_data, name_hash})

      assert_receive {:rns_announce, %RNS.Transport.Announce{} = announce}, 1000
      assert announce.dest_hash == dest_hash
      assert announce.identity == identity
      assert announce.app_data == app_data
      assert announce.name_hash == name_hash
    end

    test "unsubscribed process does not receive messages" do
      :ok = RNS.Transport.subscribe(:announces)
      :ok = RNS.Transport.unsubscribe(:announces)

      dest_hash = :crypto.strong_rand_bytes(16)
      RNS.Transport.notify_subscribers(:announces, {dest_hash, nil, nil, nil})

      refute_receive {:rns_announce, _}, 200
    end

    test "multiple subscribers all receive the message" do
      parent = self()

      pids =
        for _ <- 1..3 do
          spawn(fn ->
            :ok = RNS.Transport.subscribe(:announces)
            send(parent, :subscribed)

            receive do
              {:rns_announce, %RNS.Transport.Announce{dest_hash: hash}} ->
                send(parent, {:got_announce, self(), hash})
            end
          end)
        end

      # Wait for all subscriptions
      for _ <- 1..3, do: assert_receive(:subscribed, 1000)

      dest_hash = :crypto.strong_rand_bytes(16)
      RNS.Transport.notify_subscribers(:announces, {dest_hash, nil, nil, nil})

      for pid <- pids do
        assert_receive {:got_announce, ^pid, ^dest_hash}, 1000
      end
    end
  end
end
