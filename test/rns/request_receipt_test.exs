defmodule RNS.RequestReceiptTest do
  use ExUnit.Case, async: true

  alias RNS.RequestReceipt

  # ── Constants ──────────────────────────────────────────────────

  describe "constants" do
    test "status constants" do
      assert RequestReceipt.failed() == 0x00
      assert RequestReceipt.sent() == 0x01
      assert RequestReceipt.delivered() == 0x02
      assert RequestReceipt.receiving() == 0x03
      assert RequestReceipt.ready() == 0x04
    end
  end

  # ── Constructor ────────────────────────────────────────────────

  describe "new/1" do
    test "creates receipt with packet_receipt" do
      packet_receipt = %{truncated_hash: :crypto.strong_rand_bytes(16)}

      receipt =
        RequestReceipt.new(
          link: %{},
          timeout: 30,
          packet_receipt: packet_receipt,
          request_size: 100
        )

      assert receipt.status == RequestReceipt.sent()
      assert receipt.hash == packet_receipt.truncated_hash
      assert receipt.request_id == receipt.hash
      assert receipt.timeout == 30
      assert receipt.request_size == 100
      assert receipt.started_at != nil
      assert receipt.progress == 0.0
    end

    test "creates receipt with resource" do
      resource = %{request_id: :crypto.strong_rand_bytes(16)}

      receipt =
        RequestReceipt.new(
          link: %{},
          timeout: 60,
          resource: resource
        )

      assert receipt.hash == resource.request_id
      assert receipt.started_at == nil
    end

    test "stores callbacks" do
      resp_cb = fn _receipt -> :ok end
      fail_cb = fn _receipt -> :error end
      prog_cb = fn _receipt -> :progress end

      receipt =
        RequestReceipt.new(
          link: %{},
          timeout: 30,
          response_callback: resp_cb,
          failed_callback: fail_cb,
          progress_callback: prog_cb
        )

      assert receipt.callbacks.response == resp_cb
      assert receipt.callbacks.failed == fail_cb
      assert receipt.callbacks.progress == prog_cb
    end
  end

  # ── Status queries ─────────────────────────────────────────────

  describe "get_request_id/1" do
    test "returns request_id" do
      hash = :crypto.strong_rand_bytes(16)
      receipt = %RequestReceipt{request_id: hash}
      assert RequestReceipt.get_request_id(receipt) == hash
    end
  end

  describe "get_status/1" do
    test "returns current status" do
      receipt = %RequestReceipt{status: RequestReceipt.sent()}
      assert RequestReceipt.get_status(receipt) == RequestReceipt.sent()
    end
  end

  describe "get_progress/1" do
    test "returns progress value" do
      receipt = %RequestReceipt{progress: 0.5}
      assert RequestReceipt.get_progress(receipt) == 0.5
    end
  end

  describe "get_response/1" do
    test "returns response when ready" do
      receipt = %RequestReceipt{status: RequestReceipt.ready(), response: "data"}
      assert RequestReceipt.get_response(receipt) == "data"
    end

    test "returns nil when not ready" do
      receipt = %RequestReceipt{status: RequestReceipt.sent(), response: "data"}
      assert RequestReceipt.get_response(receipt) == nil
    end
  end

  describe "get_response_time/1" do
    test "returns response time when ready" do
      receipt = %RequestReceipt{
        status: RequestReceipt.ready(),
        started_at: 1000,
        response_concluded_at: 1005
      }

      assert RequestReceipt.get_response_time(receipt) == 5
    end

    test "returns nil when not ready" do
      receipt = %RequestReceipt{status: RequestReceipt.sent()}
      assert RequestReceipt.get_response_time(receipt) == nil
    end
  end

  describe "concluded?/1" do
    test "true when ready" do
      assert RequestReceipt.concluded?(%RequestReceipt{status: RequestReceipt.ready()})
    end

    test "true when failed" do
      assert RequestReceipt.concluded?(%RequestReceipt{status: RequestReceipt.failed()})
    end

    test "false when sent" do
      refute RequestReceipt.concluded?(%RequestReceipt{status: RequestReceipt.sent()})
    end

    test "false when delivered" do
      refute RequestReceipt.concluded?(%RequestReceipt{status: RequestReceipt.delivered()})
    end

    test "false when receiving" do
      refute RequestReceipt.concluded?(%RequestReceipt{status: RequestReceipt.receiving()})
    end
  end

  # ── Request timed out ──────────────────────────────────────────

  describe "request_timed_out/1" do
    test "marks delivered receipt as failed" do
      receipt = %RequestReceipt{
        status: RequestReceipt.delivered(),
        callbacks: %RequestReceipt.Callbacks{}
      }

      updated = RequestReceipt.request_timed_out(receipt)
      assert updated.status == RequestReceipt.failed()
      assert updated.concluded_at != nil
    end

    test "invokes failed callback" do
      test_pid = self()

      receipt = %RequestReceipt{
        status: RequestReceipt.delivered(),
        callbacks: %RequestReceipt.Callbacks{
          failed: fn _receipt -> send(test_pid, :failed_called) end
        }
      }

      RequestReceipt.request_timed_out(receipt)
      assert_receive :failed_called, 100
    end

    test "ignores non-delivered receipts" do
      receipt = %RequestReceipt{status: RequestReceipt.sent()}
      updated = RequestReceipt.request_timed_out(receipt)
      assert updated.status == RequestReceipt.sent()
    end
  end

  # ── Response received ──────────────────────────────────────────

  describe "response_received/3" do
    test "marks receipt as ready" do
      receipt = %RequestReceipt{
        status: RequestReceipt.sent(),
        callbacks: %RequestReceipt.Callbacks{}
      }

      updated = RequestReceipt.response_received(receipt, "response data")
      assert updated.status == RequestReceipt.ready()
      assert updated.response == "response data"
      assert updated.progress == 1.0
      assert updated.response_concluded_at != nil
    end

    test "includes metadata" do
      receipt = %RequestReceipt{
        status: RequestReceipt.sent(),
        callbacks: %RequestReceipt.Callbacks{}
      }

      updated = RequestReceipt.response_received(receipt, "data", %{key: "value"})
      assert updated.metadata == %{key: "value"}
    end

    test "invokes response callback" do
      test_pid = self()

      receipt = %RequestReceipt{
        status: RequestReceipt.sent(),
        callbacks: %RequestReceipt.Callbacks{
          response: fn _receipt -> send(test_pid, :response_called) end
        }
      }

      RequestReceipt.response_received(receipt, "data")
      assert_receive :response_called, 100
    end

    test "invokes progress callback" do
      test_pid = self()

      receipt = %RequestReceipt{
        status: RequestReceipt.sent(),
        callbacks: %RequestReceipt.Callbacks{
          progress: fn _receipt -> send(test_pid, :progress_called) end
        }
      }

      RequestReceipt.response_received(receipt, "data")
      assert_receive :progress_called, 100
    end

    test "ignores failed receipt" do
      receipt = %RequestReceipt{status: RequestReceipt.failed()}
      updated = RequestReceipt.response_received(receipt, "data")
      assert updated.status == RequestReceipt.failed()
    end
  end

  # ── Response resource progress ─────────────────────────────────

  describe "response_resource_progress/2" do
    test "updates status to receiving" do
      receipt = %RequestReceipt{
        status: RequestReceipt.delivered(),
        callbacks: %RequestReceipt.Callbacks{}
      }

      resource = %{progress: 0.5}
      updated = RequestReceipt.response_resource_progress(receipt, resource)
      assert updated.status == RequestReceipt.receiving()
      assert updated.progress == 0.5
    end

    test "ignores nil resource" do
      receipt = %RequestReceipt{
        status: RequestReceipt.delivered(),
        callbacks: %RequestReceipt.Callbacks{}
      }

      updated = RequestReceipt.response_resource_progress(receipt, nil)
      assert updated.status == RequestReceipt.delivered()
    end

    test "ignores failed receipt" do
      receipt = %RequestReceipt{status: RequestReceipt.failed()}
      resource = %{progress: 0.5}
      updated = RequestReceipt.response_resource_progress(receipt, resource)
      assert updated.status == RequestReceipt.failed()
    end
  end

  # ── Check timeout ──────────────────────────────────────────────

  describe "check_timeout/1" do
    test "marks as failed when timed out" do
      receipt = %RequestReceipt{
        status: RequestReceipt.delivered(),
        sent_at: System.system_time(:second) - 100,
        timeout: 50,
        callbacks: %RequestReceipt.Callbacks{}
      }

      updated = RequestReceipt.check_timeout(receipt)
      assert updated.status == RequestReceipt.failed()
    end

    test "does nothing when not timed out" do
      receipt = %RequestReceipt{
        status: RequestReceipt.delivered(),
        sent_at: System.system_time(:second),
        timeout: 60,
        callbacks: %RequestReceipt.Callbacks{}
      }

      updated = RequestReceipt.check_timeout(receipt)
      assert updated.status == RequestReceipt.delivered()
    end

    test "only checks delivered receipts" do
      receipt = %RequestReceipt{
        status: RequestReceipt.sent(),
        sent_at: System.system_time(:second) - 100,
        timeout: 50,
        callbacks: %RequestReceipt.Callbacks{}
      }

      updated = RequestReceipt.check_timeout(receipt)
      assert updated.status == RequestReceipt.sent()
    end
  end
end
