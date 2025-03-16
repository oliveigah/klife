defmodule Klife.Producer.BatcherTest do
  use ExUnit.Case
  alias Klife.Record
  alias Klife.Producer
  alias Klife.Producer.Batcher
  alias Klife.GenBatcher

  test "add records to batch" do
    user_state = %Batcher{
      producer_config: %Producer{
        acks: :all,
        batch_size_bytes: 16000,
        client_id: "my_custom_client_id",
        client_name: :my_test_client_1,
        compression_type: :none,
        delivery_timeout_ms: 60000,
        enable_idempotence: true,
        linger_ms: 10_000,
        max_in_flight_requests: 2,
        name: :my_batch_producer,
        request_timeout_ms: 15000,
        retry_backoff_ms: 1000
      },
      broker_id: 1002,
      base_sequences: %{},
      producer_epochs: %{}
    }

    state =
      %GenBatcher{
        user_state: user_state,
        current_batch: Batcher.init_batch(user_state) |> elem(1),
        current_batch_size: 0,
        current_batch_item_count: 0,
        batch_wait_time_ms: 10_000,
        in_flight_pool: [nil, nil],
        next_dispatch_msg_ref: nil,
        batch_queue: :queue.new(),
        last_batch_sent_at: System.monotonic_time(:millisecond)
      }

    %{value: rec_val, key: rec_key, headers: rec_headers} =
      rec = %Record{
        value: "1",
        key: "key_1",
        headers: [%{key: "header_key", value: "header_value"}],
        topic: "my_topic_1",
        partition: 0,
        __estimated_size: 100,
        __batch_index: 0
      }

    assert {:reply, {:ok, 60000}, new_state} =
             Batcher.handle_call(
               {:insert_on_batch, [rec], [100]},
               {self(), nil},
               state
             )

    assert new_state.current_batch_size == 100
    assert [inserted_rec_1] = new_state.current_batch.data[{"my_topic_1", 0}].records

    assert %{
             value: ^rec_val,
             key: ^rec_key,
             headers: ^rec_headers,
             attributes: 0,
             timestamp_delta: _,
             offset_delta: 0
           } = inserted_rec_1

    %{value: rec_val, key: rec_key, headers: rec_headers} =
      rec = %Record{
        value: "2",
        key: "key_2",
        headers: [%{key: "header_key2", value: "header_value2"}],
        topic: "my_topic_1",
        partition: 0,
        __estimated_size: 200,
        __batch_index: 0
      }

    assert {:reply, {:ok, 60000}, new_state} =
             Batcher.handle_call(
               {:insert_on_batch, [rec], [200]},
               {self(), nil},
               new_state
             )

    assert new_state.current_batch_size == 300

    assert [inserted_rec_2, ^inserted_rec_1] =
             new_state.current_batch.data[{"my_topic_1", 0}].records

    assert %{
             value: ^rec_val,
             key: ^rec_key,
             headers: ^rec_headers,
             attributes: 0,
             timestamp_delta: _,
             offset_delta: 1
           } = inserted_rec_2

    %{value: rec_val, key: rec_key, headers: rec_headers} =
      rec = %Record{
        value: "3",
        key: "key_3",
        headers: [%{key: "header_key3", value: "header_value3"}],
        topic: "my_topic_1",
        partition: 1,
        __estimated_size: 300,
        __batch_index: 0
      }

    assert {:reply, {:ok, 60000}, new_state} =
             Batcher.handle_call(
               {:insert_on_batch, [rec], [300]},
               {self(), nil},
               new_state
             )

    assert new_state.current_batch_size == 600

    assert [^inserted_rec_2, ^inserted_rec_1] =
             new_state.current_batch.data[{"my_topic_1", 0}].records

    assert [inserted_rec_3] = new_state.current_batch.data[{"my_topic_1", 1}].records

    assert %{
             value: ^rec_val,
             key: ^rec_key,
             headers: ^rec_headers,
             attributes: 0,
             timestamp_delta: _,
             offset_delta: 0
           } = inserted_rec_3

    %{value: rec_val, key: rec_key, headers: rec_headers} =
      rec = %Record{
        value: "4",
        key: "key_4",
        headers: [%{key: "header_key4", value: "header_value4"}],
        topic: "topic_b",
        partition: 0,
        __estimated_size: 400,
        __batch_index: 0
      }

    assert {:reply, {:ok, 60000}, new_state} =
             Batcher.handle_call(
               {:insert_on_batch, [rec], [400]},
               {self(), nil},
               new_state
             )

    assert new_state.current_batch_size == 1000

    assert [^inserted_rec_2, ^inserted_rec_1] =
             new_state.current_batch.data[{"my_topic_1", 0}].records

    assert [^inserted_rec_3] = new_state.current_batch.data[{"my_topic_1", 1}].records

    assert [inserted_rec_4] = new_state.current_batch.data[{"topic_b", 0}].records

    assert %{
             value: ^rec_val,
             key: ^rec_key,
             headers: ^rec_headers,
             attributes: 0,
             timestamp_delta: _,
             offset_delta: 0
           } = inserted_rec_4
  end

  test "batch add records to batch" do
    user_state = %Batcher{
      producer_config: %Producer{
        acks: :all,
        batch_size_bytes: 16000,
        client_id: "my_custom_client_id",
        client_name: :my_test_client_1,
        compression_type: :none,
        delivery_timeout_ms: 60000,
        enable_idempotence: true,
        linger_ms: 10_000,
        max_in_flight_requests: 2,
        name: :my_batch_producer,
        request_timeout_ms: 15000,
        retry_backoff_ms: 1000
      },
      broker_id: 1002,
      base_sequences: %{},
      producer_epochs: %{}
    }

    state =
      %GenBatcher{
        user_state: user_state,
        current_batch: Batcher.init_batch(user_state) |> elem(1),
        current_batch_size: 0,
        current_batch_item_count: 0,
        batch_wait_time_ms: 10_000,
        in_flight_pool: [nil, nil],
        next_dispatch_msg_ref: nil,
        batch_queue: :queue.new(),
        last_batch_sent_at: System.monotonic_time(:millisecond)
      }

    %{value: rec1_val, key: rec1_key, headers: rec1_headers} =
      rec1 = %Record{
        value: "1",
        key: "key_1",
        headers: [%{key: "header_key", value: "header_value"}],
        topic: "my_topic_1",
        partition: 0,
        __estimated_size: 100,
        __batch_index: 1
      }

    %{value: rec2_val, key: rec2_key, headers: rec2_headers} =
      rec2 = %Record{
        value: "2",
        key: "key_2",
        headers: [%{key: "header_key", value: "header_value"}],
        topic: "my_topic_1",
        partition: 0,
        __estimated_size: 200,
        __batch_index: 2
      }

    %{value: rec3_val, key: rec3_key, headers: rec3_headers} =
      rec3 = %Record{
        value: "3",
        key: "key_3",
        headers: [%{key: "header_key", value: "header_value"}],
        topic: "my_topic_1",
        partition: 0,
        __estimated_size: 300,
        __batch_index: 3
      }

    assert {:reply, {:ok, 60000}, new_state} =
             Batcher.handle_call(
               {:insert_on_batch, [rec1, rec2, rec3], [100, 200, 300]},
               {self(), nil},
               state
             )

    assert new_state.current_batch_size == 100 + 200 + 300

    assert [
             inserted_rec_1,
             inserted_rec_2,
             inserted_rec_3
           ] =
             new_state.current_batch.data[{"my_topic_1", 0}].records |> Enum.reverse()

    assert %{
             value: ^rec1_val,
             key: ^rec1_key,
             headers: ^rec1_headers,
             attributes: 0,
             timestamp_delta: _,
             offset_delta: 0
           } = inserted_rec_1

    assert %{
             value: ^rec2_val,
             key: ^rec2_key,
             headers: ^rec2_headers,
             attributes: 0,
             timestamp_delta: _,
             offset_delta: 1
           } = inserted_rec_2

    assert %{
             value: ^rec3_val,
             key: ^rec3_key,
             headers: ^rec3_headers,
             attributes: 0,
             timestamp_delta: _,
             offset_delta: 2
           } = inserted_rec_3

    %{value: rec1_val, key: rec1_key, headers: rec1_headers} =
      rec1 = %Record{
        value: "1",
        key: "key_1",
        headers: [%{key: "header_key", value: "header_value"}],
        topic: "my_topic_1",
        partition: 0,
        __estimated_size: 400,
        __batch_index: 1
      }

    %{value: rec2_val, key: rec2_key, headers: rec2_headers} =
      rec2 = %Record{
        value: "2",
        key: "key_2",
        headers: [%{key: "header_key", value: "header_value"}],
        topic: "my_topic_2",
        partition: 0,
        __estimated_size: 500,
        __batch_index: 2
      }

    %{value: rec3_val, key: rec3_key, headers: rec3_headers} =
      rec3 = %Record{
        value: "3",
        key: "key_3",
        headers: [%{key: "header_key", value: "header_value"}],
        topic: "my_topic_2",
        partition: 0,
        __estimated_size: 600,
        __batch_index: 3
      }

    %{value: rec4_val, key: rec4_key, headers: rec4_headers} =
      rec4 = %Record{
        value: "4",
        key: "key_4",
        headers: [%{key: "header_key", value: "header_value"}],
        topic: "my_topic_3",
        partition: 0,
        __estimated_size: 700,
        __batch_index: 4
      }

    assert {:reply, {:ok, 60000}, new_state} =
             Batcher.handle_call(
               {:insert_on_batch, [rec1, rec2, rec3, rec4], [400, 500, 600, 700]},
               {self(), nil},
               new_state
             )

    assert new_state.current_batch_size == 600 + 400 + 500 + 600 + 700

    assert [
             _,
             _,
             _,
             inserted_rec_1
           ] =
             new_state.current_batch.data[{"my_topic_1", 0}].records |> Enum.reverse()

    assert %{
             value: ^rec1_val,
             key: ^rec1_key,
             headers: ^rec1_headers,
             attributes: 0,
             timestamp_delta: _,
             offset_delta: 3
           } = inserted_rec_1

    assert [
             inserted_rec_2,
             inserted_rec_3
           ] =
             new_state.current_batch.data[{"my_topic_2", 0}].records |> Enum.reverse()

    assert %{
             value: ^rec2_val,
             key: ^rec2_key,
             headers: ^rec2_headers,
             attributes: 0,
             timestamp_delta: _,
             offset_delta: 0
           } = inserted_rec_2

    assert %{
             value: ^rec3_val,
             key: ^rec3_key,
             headers: ^rec3_headers,
             attributes: 0,
             timestamp_delta: _,
             offset_delta: 1
           } = inserted_rec_3

    assert [
             inserted_rec_4
           ] =
             new_state.current_batch.data[{"my_topic_3", 0}].records |> Enum.reverse()

    assert %{
             value: ^rec4_val,
             key: ^rec4_key,
             headers: ^rec4_headers,
             attributes: 0,
             timestamp_delta: _,
             offset_delta: 0
           } = inserted_rec_4
  end
end
