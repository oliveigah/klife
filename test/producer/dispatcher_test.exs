defmodule Klife.Producer.DispatcherTest do
  use ExUnit.Case
  alias Klife.Producer
  alias Klife.Producer.Dispatcher

  test "add records to batch" do
    %{value: rec_val, key: rec_key, headers: rec_headers} =
      rec = %{
        value: "1",
        key: "key_1",
        headers: [%{key: "header_key", value: "header_value"}]
      }

    state = %Dispatcher{
      producer_config: %Producer{
        acks: :all,
        batch_size_bytes: 16000,
        client_id: "my_custom_client_id",
        cluster_name: :my_test_cluster_1,
        compression_type: :none,
        delivery_timeout_ms: 60000,
        enable_idempotence: true,
        linger_ms: 1000,
        max_inflight_requests: 2,
        max_retries: :infinity,
        producer_name: :my_batch_producer,
        request_timeout_ms: 15000,
        retry_backoff_ms: 1000
      },
      broker_id: 1002,
      current_batch: %{}
    }

    assert {:reply, :ok, new_state} =
             Dispatcher.handle_call({:produce, rec, "topic_a", 0}, self(), state)

    assert [inserted_rec_1] = new_state.current_batch[{"topic_a", 0}].records

    assert %{
             value: ^rec_val,
             key: ^rec_key,
             headers: ^rec_headers,
             attributes: 0,
             timestamp_delta: _,
             offset_delta: 0
           } = inserted_rec_1

    %{value: rec_val, key: rec_key, headers: rec_headers} =
      rec = %{
        value: "2",
        key: "key_2",
        headers: [%{key: "header_key2", value: "header_value2"}]
      }

    assert {:reply, :ok, new_state} =
             Dispatcher.handle_call({:produce, rec, "topic_a", 0}, self(), new_state)

    assert [inserted_rec_2, ^inserted_rec_1] = new_state.current_batch[{"topic_a", 0}].records

    assert %{
             value: ^rec_val,
             key: ^rec_key,
             headers: ^rec_headers,
             attributes: 0,
             timestamp_delta: _,
             offset_delta: 1
           } = inserted_rec_2

    %{value: rec_val, key: rec_key, headers: rec_headers} =
      rec = %{
        value: "3",
        key: "key_3",
        headers: [%{key: "header_key3", value: "header_value3"}]
      }

    assert {:reply, :ok, new_state} =
             Dispatcher.handle_call({:produce, rec, "topic_a", 1}, self(), new_state)

    assert [^inserted_rec_2, ^inserted_rec_1] = new_state.current_batch[{"topic_a", 0}].records

    assert [inserted_rec_3] = new_state.current_batch[{"topic_a", 1}].records

    assert %{
             value: ^rec_val,
             key: ^rec_key,
             headers: ^rec_headers,
             attributes: 0,
             timestamp_delta: _,
             offset_delta: 0
           } = inserted_rec_3

    %{value: rec_val, key: rec_key, headers: rec_headers} =
      rec = %{
        value: "4",
        key: "key_4",
        headers: [%{key: "header_key4", value: "header_value4"}]
      }

    assert {:reply, :ok, new_state} =
             Dispatcher.handle_call({:produce, rec, "topic_b", 0}, self(), new_state)

    assert [^inserted_rec_2, ^inserted_rec_1] = new_state.current_batch[{"topic_a", 0}].records

    assert [^inserted_rec_3] = new_state.current_batch[{"topic_a", 1}].records

    assert [inserted_rec_4] = new_state.current_batch[{"topic_b", 0}].records

    assert %{
             value: ^rec_val,
             key: ^rec_key,
             headers: ^rec_headers,
             attributes: 0,
             timestamp_delta: _,
             offset_delta: 0
           } = inserted_rec_4
  end
end
