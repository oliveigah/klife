defmodule Klife.Consumer.ConsumerGroupTest do
  use ExUnit.Case, async: false

  alias Klife.Record

  alias Klife.TestUtils

  defp assert_assignment(exp_assigments, mod) do
    Enum.each(exp_assigments, fn {t, p} ->
      to_produce =
        Enum.map(1..3, fn _i ->
          %Record{topic: t, partition: p, value: :rand.bytes(10)}
        end)

      [{:ok, exp_rec1}, {:ok, exp_rec2}, {:ok, exp_rec3}] = MyClient.produce_batch(to_produce)

      assert_receive {^mod, :processed, ^t, ^p, count1, recv_rec1}, 10_000
      assert_receive {^mod, :processed, ^t, ^p, count2, recv_rec2}, 10_000
      assert_receive {^mod, :processed, ^t, ^p, count3, recv_rec3}, 10_000

      assert count1 == count2 - 1
      assert count2 == count3 - 1

      TestUtils.assert_records(recv_rec1, exp_rec1)
      TestUtils.assert_records(recv_rec2, exp_rec2)
      TestUtils.assert_records(recv_rec3, exp_rec3)
    end)
  end

  @tag capture_log: true
  @tag timeout: 120_000
  test "basic test", ctx do
    TestUtils.put_test_pid(ctx, self())

    defmodule TestCG1 do
      use Klife.Consumer.ConsumerGroup, client: MyClient

      @pid_key ctx
      @impl true
      def handle_record_batch(topic, partition, records) do
        parent = TestUtils.get_test_pid(@pid_key)

        Enum.each(records, fn %Record{} = r ->
          count_val = TestUtils.add_get_counter({__MODULE__, topic, partition})
          send(parent, {__MODULE__, :processed, topic, partition, count_val, r})
        end)

        :commit
      end

      @impl true
      def handle_consumer_start(topic, partition) do
        parent = TestUtils.get_test_pid(@pid_key)
        TestUtils.init_counter({__MODULE__, topic, partition})
        send(parent, {__MODULE__, :started_consumer, topic, partition})
        :ok
      end

      @impl true
      def handle_consumer_stop(topic, partition, reason) do
        parent = TestUtils.get_test_pid(@pid_key)
        send(parent, {__MODULE__, :stopped_consumer, topic, partition, reason})
        :ok
      end
    end

    defmodule TestCG2 do
      use Klife.Consumer.ConsumerGroup, client: MyClient

      @pid_key ctx
      @impl true
      def handle_record_batch(topic, partition, records) do
        parent = TestUtils.get_test_pid(@pid_key)

        Enum.each(records, fn r ->
          count_val = TestUtils.add_get_counter({__MODULE__, topic, partition})
          send(parent, {__MODULE__, :processed, topic, partition, count_val, r})
        end)

        :commit
      end

      @impl true
      def handle_consumer_start(topic, partition) do
        parent = TestUtils.get_test_pid(@pid_key)
        TestUtils.init_counter({__MODULE__, topic, partition})
        send(parent, {__MODULE__, :started_consumer, topic, partition})
        :ok
      end

      @impl true
      def handle_consumer_stop(topic, partition, reason) do
        parent = TestUtils.get_test_pid(@pid_key)
        send(parent, {__MODULE__, :stopped_consumer, topic, partition, reason})
        :ok
      end
    end

    defmodule TestCG3 do
      use Klife.Consumer.ConsumerGroup, client: MyClient

      @pid_key ctx
      @impl true
      def handle_record_batch(topic, partition, records) do
        parent = TestUtils.get_test_pid(@pid_key)

        Enum.each(records, fn r ->
          count_val = TestUtils.add_get_counter({__MODULE__, topic, partition})
          send(parent, {__MODULE__, :processed, topic, partition, count_val, r})
        end)

        :commit
      end

      @impl true
      def handle_consumer_start(topic, partition) do
        parent = TestUtils.get_test_pid(@pid_key)
        TestUtils.init_counter({__MODULE__, topic, partition})
        send(parent, {__MODULE__, :started_consumer, topic, partition})
        :ok
      end

      @impl true
      def handle_consumer_stop(topic, partition, reason) do
        parent = TestUtils.get_test_pid(@pid_key)
        send(parent, {__MODULE__, :stopped_consumer, topic, partition, reason})
        :ok
      end
    end

    consumer_opts = [
      topics: [
        [name: "test_consumer_topic_1"],
        [name: "test_consumer_topic_2"]
      ],
      group_name: Base.encode64(:rand.bytes(10))
    ]

    cg1_pid = start_supervised!({TestCG1, consumer_opts}, id: :cg1, restart: :temporary)

    cg1_assignments = [
      {"test_consumer_topic_1", 0},
      {"test_consumer_topic_1", 1},
      {"test_consumer_topic_1", 2},
      {"test_consumer_topic_1", 3},
      {"test_consumer_topic_2", 0},
      {"test_consumer_topic_2", 1}
    ]

    Enum.each(cg1_assignments, fn {t, p} ->
      assert_receive {TestCG1, :started_consumer, ^t, ^p}, 10_000
    end)

    assert_assignment(cg1_assignments, TestCG1)

    cg2_pid = start_supervised!({TestCG2, consumer_opts}, id: :cg2, restart: :temporary)

    assert_receive {TestCG1, :stopped_consumer, stopped_topic0, p0,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    assert_receive {TestCG1, :stopped_consumer, stopped_topic1, p1,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    assert_receive {TestCG1, :stopped_consumer, stopped_topic2, p2,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    cg2_assignments = [
      {stopped_topic0, p0},
      {stopped_topic1, p1},
      {stopped_topic2, p2}
    ]

    cg1_assignments = cg1_assignments -- cg2_assignments

    Enum.each(cg2_assignments, fn {t, p} ->
      assert_receive {TestCG2, :started_consumer, ^t, ^p}, 10_000
    end)

    assert_assignment(cg1_assignments, TestCG1)
    assert_assignment(cg2_assignments, TestCG2)

    start_supervised!({TestCG3, consumer_opts}, id: :cg3, restart: :temporary)

    assert_receive {TestCG1, :stopped_consumer, stopped_topic0, p0,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    assert_receive {TestCG2, :stopped_consumer, stopped_topic1, p1,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    cg3_assignments = [
      {stopped_topic0, p0},
      {stopped_topic1, p1}
    ]

    cg1_assignments = cg1_assignments -- cg3_assignments
    cg2_assignments = cg2_assignments -- cg3_assignments

    Enum.each(cg3_assignments, fn {t, p} ->
      assert_receive {TestCG3, :started_consumer, ^t, ^p}, 10_000
    end)

    assert_assignment(cg1_assignments, TestCG1)
    assert_assignment(cg2_assignments, TestCG2)
    assert_assignment(cg3_assignments, TestCG3)

    Process.exit(cg1_pid, :test)

    assert_receive {TestCG1, :stopped_consumer, stopped_topic0, p0,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    assert_receive {TestCG1, :stopped_consumer, stopped_topic1, p1,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    assert_receive {TestCG2, :started_consumer, cg2_t, cg2_p}, 10_000
    assert_receive {TestCG3, :started_consumer, cg3_t, cg3_p}, 10_000

    stopped_list = [{stopped_topic0, p0}, {stopped_topic1, p1}]

    assert {cg2_t, cg2_p} in stopped_list
    assert {cg3_t, cg3_p} in stopped_list

    cg2_assignments = cg2_assignments ++ [{cg2_t, cg2_p}]
    cg3_assignments = cg3_assignments ++ [{cg3_t, cg3_p}]

    assert length(cg2_assignments) == 3
    assert_assignment(cg2_assignments, TestCG2)

    assert length(cg3_assignments) == 3
    assert_assignment(cg3_assignments, TestCG3)

    Process.exit(cg2_pid, :test)

    assert_receive {TestCG2, :stopped_consumer, stopped_topic0, p0,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    assert_receive {TestCG2, :stopped_consumer, stopped_topic1, p1,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    assert_receive {TestCG2, :stopped_consumer, stopped_topic2, p2,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   10_000

    assert_receive {TestCG3, :started_consumer, ^stopped_topic0, ^p0}, 10_000
    assert_receive {TestCG3, :started_consumer, ^stopped_topic1, ^p1}, 10_000
    assert_receive {TestCG3, :started_consumer, ^stopped_topic2, ^p2}, 10_000

    cg3_assignments = cg3_assignments ++ cg2_assignments
    assert length(cg3_assignments) == 6
    assert_assignment(cg3_assignments, TestCG3)
  end

  test "handle returns", ctx do
    TestUtils.put_test_pid(ctx, self())

    defmodule TestCG do
      use Klife.Consumer.ConsumerGroup, client: MyClient

      @pid_key ctx
      @impl true
      def handle_record_batch(topic, partition, records) do
        parent = TestUtils.get_test_pid(@pid_key)

        Enum.map(records, fn %Record{} = rec ->
          count_val = TestUtils.add_get_counter({__MODULE__, topic, partition})
          send(parent, {__MODULE__, :processed, topic, partition, count_val, rec})
          curr_attempts = rec.consumer_attempts

          case String.split(rec.value, "___") do
            [command, _rest] ->
              [action, cmd_attempts] = String.split(command, "_at_")

              if(curr_attempts == String.to_integer(cmd_attempts)) do
                case action do
                  "success" -> {:commit, rec}
                end
              else
                {:retry, rec}
              end

            _ ->
              {:commit, rec}
          end
        end)
      end

      @impl true
      def handle_consumer_start(topic, partition) do
        TestUtils.init_counter({__MODULE__, topic, partition})
        parent = TestUtils.get_test_pid(@pid_key)
        send(parent, {__MODULE__, :started_consumer, topic, partition})
        :ok
      end

      @impl true
      def handle_consumer_stop(topic, partition, reason) do
        parent = TestUtils.get_test_pid(@pid_key)
        send(parent, {__MODULE__, :stopped_consumer, topic, partition, reason})
        :ok
      end
    end

    consumer_opts = [
      topics: [
        [name: "test_consumer_topic_1"],
        [name: "test_consumer_topic_2"]
      ],
      group_name: Base.encode64(:rand.bytes(10))
    ]

    start_supervised!({TestCG, consumer_opts}, id: :cg, restart: :temporary)

    cg_assignments = [
      {"test_consumer_topic_1", 0},
      {"test_consumer_topic_1", 1},
      {"test_consumer_topic_1", 2},
      {"test_consumer_topic_1", 3},
      {"test_consumer_topic_2", 0},
      {"test_consumer_topic_2", 1}
    ]

    Enum.each(cg_assignments, fn {t, p} ->
      assert_receive {TestCG, :started_consumer, ^t, ^p}, 10_000
    end)

    assert_assignment(cg_assignments, TestCG)

    topic = "test_consumer_topic_1"

    recs = [
      %Record{
        value: "success_at_0___#{Base.encode64(:rand.bytes(10))}",
        topic: topic,
        partition: 0
      },
      %Record{
        value: "success_at_1___#{Base.encode64(:rand.bytes(10))}",
        topic: topic,
        partition: 0
      },
      %Record{
        value: "success_at_2___#{Base.encode64(:rand.bytes(10))}",
        topic: topic,
        partition: 0
      },
      %Record{
        value: "success_at_2___#{Base.encode64(:rand.bytes(10))}",
        topic: topic,
        partition: 0
      },
      %Record{
        value: "success_at_2___#{Base.encode64(:rand.bytes(10))}",
        topic: topic,
        partition: 0
      },
      %Record{
        value: "success_at_3___#{Base.encode64(:rand.bytes(10))}",
        topic: topic,
        partition: 0
      }
    ]

    [
      {:ok, produced_rec1},
      {:ok, produced_rec2},
      {:ok, produced_rec3},
      {:ok, produced_rec4},
      {:ok, produced_rec5},
      {:ok, produced_rec6}
    ] = MyClient.produce_batch(recs)

    assert_receive {TestCG, :processed, ^topic, 0, count1, recv_rec1}, 10_000
    TestUtils.assert_records(recv_rec1, produced_rec1)

    assert_receive {TestCG, :processed, ^topic, 0, count2, recv_rec2}, 10_000
    TestUtils.assert_records(recv_rec2, produced_rec2)

    assert_receive {TestCG, :processed, ^topic, 0, count3, recv_rec3}, 10_000
    TestUtils.assert_records(recv_rec3, produced_rec3)

    assert_receive {TestCG, :processed, ^topic, 0, count4, recv_rec4}, 10_000
    TestUtils.assert_records(recv_rec4, produced_rec4)

    assert_receive {TestCG, :processed, ^topic, 0, count5, recv_rec5}, 10_000
    TestUtils.assert_records(recv_rec5, produced_rec5)

    assert_receive {TestCG, :processed, ^topic, 0, count6, recv_rec6}, 10_000
    TestUtils.assert_records(recv_rec6, produced_rec6)

    assert [count1, count2, count3, count4, count5, count6] ==
             Enum.sort([count1, count2, count3, count4, count5, count6])

    #  Second phase

    assert_receive {TestCG, :processed, ^topic, 0, count2, recv_rec2}, 10_000
    TestUtils.assert_records(recv_rec2, produced_rec2)

    assert_receive {TestCG, :processed, ^topic, 0, count3, recv_rec3}, 10_000
    TestUtils.assert_records(recv_rec3, produced_rec3)

    assert_receive {TestCG, :processed, ^topic, 0, count4, recv_rec4}, 10_000
    TestUtils.assert_records(recv_rec4, produced_rec4)

    assert_receive {TestCG, :processed, ^topic, 0, count5, recv_rec5}, 10_000
    TestUtils.assert_records(recv_rec5, produced_rec5)

    assert_receive {TestCG, :processed, ^topic, 0, count6, recv_rec6}, 10_000
    TestUtils.assert_records(recv_rec6, produced_rec6)

    assert [count2, count3, count4, count5, count6] ==
             Enum.sort([count2, count3, count4, count5, count6])

    #  Third phase

    assert_receive {TestCG, :processed, ^topic, 0, count3, recv_rec3}, 10_000
    TestUtils.assert_records(recv_rec3, produced_rec3)

    assert_receive {TestCG, :processed, ^topic, 0, count4, recv_rec4}, 10_000
    TestUtils.assert_records(recv_rec4, produced_rec4)

    assert_receive {TestCG, :processed, ^topic, 0, count5, recv_rec5}, 10_000
    TestUtils.assert_records(recv_rec5, produced_rec5)

    assert_receive {TestCG, :processed, ^topic, 0, count6, recv_rec6}, 10_000
    TestUtils.assert_records(recv_rec6, produced_rec6)

    assert [count3, count4, count5, count6] ==
             Enum.sort([count3, count4, count5, count6])

    #  Fourth phase

    assert_receive {TestCG, :processed, ^topic, 0, _count6, recv_rec6}, 10_000
    TestUtils.assert_records(recv_rec6, produced_rec6)

    refute_receive {TestCG, :processed, ^topic, 0, _count, _rec}, 1000
  end
end
