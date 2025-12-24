defmodule Klife.Consumer.ConsumerGroupTest do
  use ExUnit.Case, async: false

  alias Klife.Record

  alias Klife.TestUtils

  defmodule CGTest do
    defmacro __using__(opts) do
      quote bind_quoted: [opts: opts] do
        use Klife.Consumer.ConsumerGroup, client: MyClient

        @impl true
        def handle_record_batch(topic, partition, _cg_name, records) do
          Enum.map(records, fn %Record{} = rec ->
            send(unquote(opts[:parent_pid]), {__MODULE__, :processed, topic, partition, rec})

            case String.split(rec.value, "___") do
              [command_str, rest] ->
                [action, attempts] = String.split(command_str, "_")

                if rec.consumer_attempts <= String.to_integer(attempts),
                  do: {String.to_existing_atom(action), rec},
                  else: {:commit, rec}

              _ ->
                {:commit, rec}
            end
          end)
        end

        @impl true
        def handle_consumer_start(topic, partition, _cg_name) do
          send(unquote(opts[:parent_pid]), {__MODULE__, :started_consumer, topic, partition})
          :ok
        end

        @impl true
        def handle_consumer_stop(topic, partition, _cg_name, reason) do
          send(
            unquote(opts[:parent_pid]),
            {__MODULE__, :stopped_consumer, topic, partition, reason}
          )

          :ok
        end
      end
    end
  end

  defp assert_assignment(exp_assigments, mod) do
    Enum.each(exp_assigments, fn {t, p} ->
      [
        {:ok, %Record{offset: offset1} = exp_rec1},
        {:ok, %Record{offset: offset2} = exp_rec2},
        {:ok, %Record{offset: offset3} = exp_rec3}
      ] =
        MyClient.produce_batch([
          %Record{topic: t, partition: p, value: :rand.bytes(10)},
          %Record{topic: t, partition: p, value: :rand.bytes(10)},
          %Record{topic: t, partition: p, value: :rand.bytes(10)}
        ])

      [
        {:ok, %Record{offset: offset4} = exp_rec4}
      ] =
        MyClient.produce_batch([
          %Record{topic: t, partition: p, value: :rand.bytes(10)}
        ])

      [
        {:ok, %Record{offset: offset5} = exp_rec5},
        {:ok, %Record{offset: offset6} = exp_rec6}
      ] =
        MyClient.produce_batch([
          %Record{topic: t, partition: p, value: :rand.bytes(10)},
          %Record{topic: t, partition: p, value: :rand.bytes(10)}
        ])

      assert_receive {^mod, :processed, ^t, ^p, %Record{offset: ^offset1} = recv_rec1}, 5_000
      assert_receive {^mod, :processed, ^t, ^p, %Record{offset: ^offset2} = recv_rec2}, 5_000
      assert_receive {^mod, :processed, ^t, ^p, %Record{offset: ^offset3} = recv_rec3}, 5_000
      assert_receive {^mod, :processed, ^t, ^p, %Record{offset: ^offset4} = recv_rec4}, 5_000
      assert_receive {^mod, :processed, ^t, ^p, %Record{offset: ^offset5} = recv_rec5}, 5_000
      assert_receive {^mod, :processed, ^t, ^p, %Record{offset: ^offset6} = recv_rec6}, 5_000

      TestUtils.assert_records(recv_rec1, exp_rec1)
      TestUtils.assert_records(recv_rec2, exp_rec2)
      TestUtils.assert_records(recv_rec3, exp_rec3)
      TestUtils.assert_records(recv_rec4, exp_rec4)
      TestUtils.assert_records(recv_rec5, exp_rec5)
      TestUtils.assert_records(recv_rec6, exp_rec6)
    end)
  end

  test "basic consume test", ctx do
    parent_pid = self()

    defmodule MyTestCG do
      use CGTest, parent_pid: parent_pid
    end

    consumer_opts = [
      topics: [
        [name: "test_consumer_topic_1"],
        [name: "test_consumer_topic_2"]
      ],
      group_name: Base.encode64(:rand.bytes(10))
      # fetch_strategy: {:shared, MyClient.get_default_fetcher()}
    ]

    start_supervised!({MyTestCG, consumer_opts}, id: :cg1, restart: :temporary)

    cg_assignments = [
      {"test_consumer_topic_1", 0},
      {"test_consumer_topic_1", 1},
      {"test_consumer_topic_1", 2},
      {"test_consumer_topic_1", 3},
      {"test_consumer_topic_2", 0},
      {"test_consumer_topic_2", 1}
    ]

    Process.sleep(5000)

    Enum.each(cg_assignments, fn {t, p} ->
      assert_receive {MyTestCG, :started_consumer, ^t, ^p}, 5_000
    end)

    assert_assignment(cg_assignments, MyTestCG)

    [
      {:ok, %Record{offset: offset1} = exp_rec1},
      {:ok, %Record{offset: offset2} = exp_rec2}
    ] =
      MyClient.produce_batch([
        %Record{topic: "test_consumer_topic_1", partition: 0, value: :rand.bytes(10)},
        %Record{
          topic: "test_consumer_topic_1",
          partition: 0,
          value: "retry_2" <> "___" <> :rand.bytes(10)
        }
      ])

    assert_receive {MyTestCG, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset1} = recv_rec1},
                   5_000

    TestUtils.assert_records(recv_rec1, exp_rec1)

    assert_receive {MyTestCG, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset2, consumer_attempts: 0} = recv_rec2_1},
                   5_000

    TestUtils.assert_records(recv_rec2_1, exp_rec2)

    assert_receive {MyTestCG, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset2, consumer_attempts: 1} = recv_rec2_2},
                   5_000

    TestUtils.assert_records(recv_rec2_2, exp_rec2)

    assert_receive {MyTestCG, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset2, consumer_attempts: 2} = recv_rec2_3},
                   5_000

    TestUtils.assert_records(recv_rec2_3, exp_rec2)

    assert_receive {MyTestCG, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset2, consumer_attempts: 3} = recv_rec2_4},
                   5_000

    TestUtils.assert_records(recv_rec2_4, exp_rec2)

    refute_receive {MyTestCG, :processed, _any_topic, _any_partition, _any_rec}, 5_000
  end

  test "basic consume test - shared fetch", ctx do
    parent_pid = self()

    defmodule MyTestCG8 do
      use CGTest, parent_pid: parent_pid
    end

    consumer_opts = [
      topics: [
        [name: "test_consumer_topic_1"],
        [name: "test_consumer_topic_2"]
      ],
      group_name: Base.encode64(:rand.bytes(10)),
      fetch_strategy: {:shared, MyClient.get_default_fetcher()}
    ]

    start_supervised!({MyTestCG8, consumer_opts}, id: :cg1, restart: :temporary)

    cg_assignments = [
      {"test_consumer_topic_1", 0},
      {"test_consumer_topic_1", 1},
      {"test_consumer_topic_1", 2},
      {"test_consumer_topic_1", 3},
      {"test_consumer_topic_2", 0},
      {"test_consumer_topic_2", 1}
    ]

    Process.sleep(5000)

    Enum.each(cg_assignments, fn {t, p} ->
      assert_receive {MyTestCG8, :started_consumer, ^t, ^p}, 5_000
    end)

    assert_assignment(cg_assignments, MyTestCG8)

    [
      {:ok, %Record{offset: offset1} = exp_rec1},
      {:ok, %Record{offset: offset2} = exp_rec2}
    ] =
      MyClient.produce_batch([
        %Record{topic: "test_consumer_topic_1", partition: 0, value: :rand.bytes(10)},
        %Record{
          topic: "test_consumer_topic_1",
          partition: 0,
          value: "retry_2" <> "___" <> :rand.bytes(10)
        }
      ])

    assert_receive {MyTestCG8, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset1} = recv_rec1},
                   5_000

    TestUtils.assert_records(recv_rec1, exp_rec1)

    assert_receive {MyTestCG8, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset2, consumer_attempts: 0} = recv_rec2_1},
                   5_000

    TestUtils.assert_records(recv_rec2_1, exp_rec2)

    assert_receive {MyTestCG8, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset2, consumer_attempts: 1} = recv_rec2_2},
                   5_000

    TestUtils.assert_records(recv_rec2_2, exp_rec2)

    assert_receive {MyTestCG8, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset2, consumer_attempts: 2} = recv_rec2_3},
                   5_000

    TestUtils.assert_records(recv_rec2_3, exp_rec2)

    assert_receive {MyTestCG8, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset2, consumer_attempts: 3} = recv_rec2_4},
                   5_000

    TestUtils.assert_records(recv_rec2_4, exp_rec2)

    refute_receive {MyTestCG8, :processed, _any_topic, _any_partition, _any_rec}, 5_000
  end

  test "should not read uncommitted records", ctx do
    parent_pid = self()

    defmodule MyTestCG6 do
      use CGTest, parent_pid: parent_pid
    end

    consumer_opts = [
      topics: [
        [name: "test_consumer_topic_1"]
      ],
      group_name: Base.encode64(:rand.bytes(10))
    ]

    start_supervised!({MyTestCG6, consumer_opts}, id: :cg1, restart: :temporary)

    cg_assignments = [
      {"test_consumer_topic_1", 0},
      {"test_consumer_topic_1", 1},
      {"test_consumer_topic_1", 2},
      {"test_consumer_topic_1", 3}
    ]

    Enum.each(cg_assignments, fn {t, p} ->
      assert_receive {MyTestCG6, :started_consumer, ^t, ^p}, 5_000
    end)

    assert_assignment(cg_assignments, MyTestCG6)

    {:ok,
     [
       %Record{offset: offset1} = exp_rec1,
       %Record{offset: offset2} = exp_rec2
     ]} =
      MyClient.transaction(fn ->
        [{:ok, exp_rec1}, {:ok, exp_rec2}] =
          MyClient.produce_batch([
            %Record{topic: "test_consumer_topic_1", partition: 0, value: "aaaa"},
            %Record{
              topic: "test_consumer_topic_1",
              partition: 0,
              value: "retry_2" <> "___" <> "bbbb"
            }
          ])

        refute_receive {MyTestCG6, :processed, _any_topic, _any_partition, _any_rec}, 5_000

        {:ok, [exp_rec1, exp_rec2]}
      end)

    assert_receive {MyTestCG6, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset1} = recv_rec1},
                   5_000

    TestUtils.assert_records(recv_rec1, exp_rec1)

    assert_receive {MyTestCG6, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset2, consumer_attempts: 0} = recv_rec2_1},
                   5_000

    TestUtils.assert_records(recv_rec2_1, exp_rec2)

    assert_receive {MyTestCG6, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset2, consumer_attempts: 1} = recv_rec2_2},
                   5_000

    TestUtils.assert_records(recv_rec2_2, exp_rec2)

    assert_receive {MyTestCG6, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset2, consumer_attempts: 2} = recv_rec2_3},
                   5_000

    TestUtils.assert_records(recv_rec2_3, exp_rec2)

    assert_receive {MyTestCG6, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset2, consumer_attempts: 3} = recv_rec2_4},
                   5_000

    TestUtils.assert_records(recv_rec2_4, exp_rec2)

    refute_receive {MyTestCG6, :processed, _any_topic, _any_partition, _any_rec}, 5_000

    MyClient.transaction(fn ->
      [{:ok, _exp_rec1}, {:ok, _exp_rec2}] =
        MyClient.produce_batch([
          %Record{topic: "test_consumer_topic_1", partition: 0, value: "ccccc"},
          %Record{
            topic: "test_consumer_topic_1",
            partition: 0,
            value: "retry_2" <> "___" <> "ddddd"
          }
        ])

      refute_receive {MyTestCG6, :processed, _any_topic, _any_partition, _any_rec}, 5_000

      :some_error
    end)

    refute_receive {MyTestCG6, :processed, _any_topic, _any_partition, _any_rec}, 5_000

    assert_assignment(cg_assignments, MyTestCG6)
  end

  test "should not read uncommitted records - batch with only filtered records", ctx do
    parent_pid = self()

    defmodule MyTestCG7 do
      use CGTest, parent_pid: parent_pid
    end

    consumer_opts = [
      topics: [
        [name: "test_consumer_topic_1", fetch_max_bytes: 1]
      ],
      group_name: Base.encode64(:rand.bytes(10))
    ]

    start_supervised!({MyTestCG7, consumer_opts}, id: :cg1, restart: :temporary)

    cg_assignments = [
      {"test_consumer_topic_1", 0},
      {"test_consumer_topic_1", 1},
      {"test_consumer_topic_1", 2},
      {"test_consumer_topic_1", 3}
    ]

    Enum.each(cg_assignments, fn {t, p} ->
      assert_receive {MyTestCG7, :started_consumer, ^t, ^p}, 5_000
    end)

    assert_assignment(cg_assignments, MyTestCG7)

    {:ok,
     [
       %Record{offset: offset1} = exp_rec1,
       %Record{offset: offset2} = exp_rec2
     ]} =
      MyClient.transaction(fn ->
        [{:ok, exp_rec1}, {:ok, exp_rec2}] =
          MyClient.produce_batch([
            %Record{topic: "test_consumer_topic_1", partition: 0, value: "aaaa"},
            %Record{
              topic: "test_consumer_topic_1",
              partition: 0,
              value: "retry_2" <> "___" <> "bbbb"
            }
          ])

        refute_receive {MyTestCG7, :processed, _any_topic, _any_partition, _any_rec}, 5_000

        {:ok, [exp_rec1, exp_rec2]}
      end)

    assert_receive {MyTestCG7, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset1} = recv_rec1},
                   5_000

    TestUtils.assert_records(recv_rec1, exp_rec1)

    assert_receive {MyTestCG7, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset2, consumer_attempts: 0} = recv_rec2_1},
                   5_000

    TestUtils.assert_records(recv_rec2_1, exp_rec2)

    assert_receive {MyTestCG7, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset2, consumer_attempts: 1} = recv_rec2_2},
                   5_000

    TestUtils.assert_records(recv_rec2_2, exp_rec2)

    assert_receive {MyTestCG7, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset2, consumer_attempts: 2} = recv_rec2_3},
                   5_000

    TestUtils.assert_records(recv_rec2_3, exp_rec2)

    assert_receive {MyTestCG7, :processed, "test_consumer_topic_1", 0,
                    %Record{offset: ^offset2, consumer_attempts: 3} = recv_rec2_4},
                   5_000

    TestUtils.assert_records(recv_rec2_4, exp_rec2)

    refute_receive {MyTestCG7, :processed, _any_topic, _any_partition, _any_rec}, 5_000

    MyClient.transaction(fn ->
      [{:ok, _exp_rec1}, {:ok, _exp_rec2}] =
        MyClient.produce_batch([
          %Record{topic: "test_consumer_topic_1", partition: 0, value: "ccccc"},
          %Record{
            topic: "test_consumer_topic_1",
            partition: 0,
            value: "retry_2" <> "___" <> "ddddd"
          }
        ])

      refute_receive {MyTestCG7, :processed, _any_topic, _any_partition, _any_rec}, 5_000

      :some_error
    end)

    refute_receive {MyTestCG7, :processed, _any_topic, _any_partition, _any_rec}, 5_000

    assert_assignment(cg_assignments, MyTestCG7)
  end

  @tag capture_log: true
  @tag timeout: 120_000
  test "offset reset policy and offset commit", _ctx do
    parent_pid = self()

    defmodule MyTestCG5 do
      use CGTest, parent_pid: parent_pid
    end

    earliest_topic = Base.encode16(:rand.bytes(10))
    other_topic = Base.encode16(:rand.bytes(10))

    consumer_opts = [
      topics: [
        [name: earliest_topic, offset_reset_policy: :earliest],
        [name: other_topic]
      ],
      group_name: Base.encode64(:rand.bytes(10))
    ]

    :ok =
      TestUtils.create_topics(MyClient, [
        %{name: earliest_topic, partitions: 4},
        %{name: other_topic, partitions: 2}
      ])

    [{:ok, prev_rec1}, {:ok, prev_rec2}, {:ok, prev_rec3}, {:ok, _prev_rec4}, {:ok, _prev_rec5}] =
      MyClient.produce_batch([
        %Record{topic: earliest_topic, partition: 0, value: :rand.bytes(10)},
        %Record{topic: earliest_topic, partition: 1, value: :rand.bytes(10)},
        %Record{topic: earliest_topic, partition: 2, value: :rand.bytes(10)},
        %Record{topic: other_topic, partition: 0, value: :rand.bytes(10)},
        %Record{topic: other_topic, partition: 0, value: :rand.bytes(10)}
      ])

    test_cg_pid = start_supervised!({MyTestCG5, consumer_opts}, restart: :temporary)
    Process.monitor(test_cg_pid)

    cg_assignments = [
      {earliest_topic, 0},
      {earliest_topic, 1},
      {earliest_topic, 2},
      {earliest_topic, 3},
      {other_topic, 0},
      {other_topic, 1}
    ]

    Enum.each(cg_assignments, fn {t, p} ->
      assert_receive {MyTestCG5, :started_consumer, ^t, ^p}, 5_000
    end)

    assert_receive {MyTestCG5, :processed, ^earliest_topic, 0, recv_rec1}, 5_000
    assert_receive {MyTestCG5, :processed, ^earliest_topic, 1, recv_rec2}, 5_000
    assert_receive {MyTestCG5, :processed, ^earliest_topic, 2, recv_rec3}, 5_000
    refute_receive {MyTestCG5, :processed, ^other_topic, _, _recv_rec1}, 5_000

    TestUtils.assert_records(recv_rec1, prev_rec1)
    TestUtils.assert_records(recv_rec2, prev_rec2)
    TestUtils.assert_records(recv_rec3, prev_rec3)

    assert_assignment(cg_assignments, MyTestCG5)

    true = Process.exit(test_cg_pid, :test)

    Enum.each(cg_assignments, fn {t, p} ->
      assert_receive {MyTestCG5, :stopped_consumer, ^t, ^p,
                      {:shutdown, {:assignment_revoked, _tid, ^p}}},
                     5_000
    end)

    assert_receive {:DOWN, _ref, :process, ^test_cg_pid, :test}

    start_supervised!({MyTestCG5, consumer_opts}, restart: :temporary)

    Enum.each(cg_assignments, fn {t, p} ->
      assert_receive {MyTestCG5, :started_consumer, ^t, ^p}, 5_000
    end)

    refute_receive {MyTestCG5, :processed, _any_topic, _, _recv_rec1}, 5_000

    assert_assignment(cg_assignments, MyTestCG5)
  end

  @tag capture_log: true
  @tag timeout: 120_000
  test "basic rebalance test", ctx do
    parent_pid = self()

    defmodule MyTestCG1 do
      use CGTest, parent_pid: parent_pid
    end

    defmodule MyTestCG2 do
      use CGTest, parent_pid: parent_pid
    end

    defmodule MyTestCG3 do
      use CGTest, parent_pid: parent_pid
    end

    consumer_opts = [
      topics: [
        [name: "test_consumer_topic_1"],
        [name: "test_consumer_topic_2"]
      ],
      group_name: Base.encode64(:rand.bytes(10))
    ]

    cg1_pid = start_supervised!({MyTestCG1, consumer_opts}, id: :cg1, restart: :temporary)

    cg1_assignments = [
      {"test_consumer_topic_1", 0},
      {"test_consumer_topic_1", 1},
      {"test_consumer_topic_1", 2},
      {"test_consumer_topic_1", 3},
      {"test_consumer_topic_2", 0},
      {"test_consumer_topic_2", 1}
    ]

    Enum.each(cg1_assignments, fn {t, p} ->
      assert_receive {MyTestCG1, :started_consumer, ^t, ^p}, 5_000
    end)

    assert_assignment(cg1_assignments, MyTestCG1)

    cg2_pid = start_supervised!({MyTestCG2, consumer_opts}, id: :cg2, restart: :temporary)

    assert_receive {MyTestCG1, :stopped_consumer, stopped_topic0, p0,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   5_000

    assert_receive {MyTestCG1, :stopped_consumer, stopped_topic1, p1,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   5_000

    assert_receive {MyTestCG1, :stopped_consumer, stopped_topic2, p2,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   5_000

    cg2_assignments = [
      {stopped_topic0, p0},
      {stopped_topic1, p1},
      {stopped_topic2, p2}
    ]

    cg1_assignments = cg1_assignments -- cg2_assignments

    Enum.each(cg2_assignments, fn {t, p} ->
      assert_receive {MyTestCG2, :started_consumer, ^t, ^p}, 5_000
    end)

    assert_assignment(cg1_assignments, MyTestCG1)
    assert_assignment(cg2_assignments, MyTestCG2)

    start_supervised!({MyTestCG3, consumer_opts}, id: :cg3, restart: :temporary)

    assert_receive {MyTestCG1, :stopped_consumer, stopped_topic0, p0,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   5_000

    assert_receive {MyTestCG2, :stopped_consumer, stopped_topic1, p1,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   5_000

    cg3_assignments = [
      {stopped_topic0, p0},
      {stopped_topic1, p1}
    ]

    cg1_assignments = cg1_assignments -- cg3_assignments
    cg2_assignments = cg2_assignments -- cg3_assignments

    Enum.each(cg3_assignments, fn {t, p} ->
      assert_receive {MyTestCG3, :started_consumer, ^t, ^p}, 5_000
    end)

    assert_assignment(cg1_assignments, MyTestCG1)
    assert_assignment(cg2_assignments, MyTestCG2)
    assert_assignment(cg3_assignments, MyTestCG3)

    Process.exit(cg1_pid, :test)

    assert_receive {MyTestCG1, :stopped_consumer, stopped_topic0, p0,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   5_000

    assert_receive {MyTestCG1, :stopped_consumer, stopped_topic1, p1,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   5_000

    assert_receive {MyTestCG2, :started_consumer, cg2_t, cg2_p}, 5_000
    assert_receive {MyTestCG3, :started_consumer, cg3_t, cg3_p}, 5_000

    stopped_list = [{stopped_topic0, p0}, {stopped_topic1, p1}]

    assert {cg2_t, cg2_p} in stopped_list
    assert {cg3_t, cg3_p} in stopped_list

    cg2_assignments = cg2_assignments ++ [{cg2_t, cg2_p}]
    cg3_assignments = cg3_assignments ++ [{cg3_t, cg3_p}]

    assert length(cg2_assignments) == 3
    assert_assignment(cg2_assignments, MyTestCG2)

    assert length(cg3_assignments) == 3
    assert_assignment(cg3_assignments, MyTestCG3)

    Process.exit(cg2_pid, :test)

    assert_receive {MyTestCG2, :stopped_consumer, stopped_topic0, p0,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   5_000

    assert_receive {MyTestCG2, :stopped_consumer, stopped_topic1, p1,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   5_000

    assert_receive {MyTestCG2, :stopped_consumer, stopped_topic2, p2,
                    {:shutdown, {:assignment_revoked, _, _}}},
                   5_000

    assert_receive {MyTestCG3, :started_consumer, ^stopped_topic0, ^p0}, 5_000
    assert_receive {MyTestCG3, :started_consumer, ^stopped_topic1, ^p1}, 5_000
    assert_receive {MyTestCG3, :started_consumer, ^stopped_topic2, ^p2}, 5_000

    cg3_assignments = cg3_assignments ++ cg2_assignments
    assert length(cg3_assignments) == 6
    assert_assignment(cg3_assignments, MyTestCG3)
  end

  @tag capture_log: true
  @tag cluster_change: true
  @tag timeout: 120_000
  test "should be able to handle coordinator changes", ctx do
    parent_pid = self()

    defmodule MyTestCG4 do
      use CGTest, parent_pid: parent_pid
    end

    consumer_opts = [
      topics: [
        [name: "test_consumer_topic_1"],
        [name: "test_consumer_topic_2"]
      ],
      group_name: Base.encode64(:rand.bytes(10))
    ]

    cg_pid = start_supervised!({MyTestCG4, consumer_opts}, id: :cg)

    cg_assignments = [
      {"test_consumer_topic_1", 0},
      {"test_consumer_topic_1", 1},
      {"test_consumer_topic_1", 2},
      {"test_consumer_topic_1", 3},
      {"test_consumer_topic_2", 0},
      {"test_consumer_topic_2", 1}
    ]

    Enum.each(cg_assignments, fn {t, p} ->
      assert_receive {MyTestCG4, :started_consumer, ^t, ^p}, 5_000
    end)

    assert_assignment(cg_assignments, MyTestCG4)

    cg_state = :sys.get_state(cg_pid)

    {:ok, broker_name} = TestUtils.stop_broker(MyClient, cg_state.coordinator_id)

    new_cg_state = :sys.get_state(cg_pid)

    assert new_cg_state.coordinator_id != cg_state.coordinator_id

    assert_assignment(cg_assignments, MyTestCG4)

    {:ok, _new_boker_id} = TestUtils.start_broker(broker_name, MyClient)
  end
end
