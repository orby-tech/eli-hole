defmodule EliHole.DNS.SpeedTrackerTest do
  use ExUnit.Case

  alias EliHole.DNS.SpeedTracker

  @upstream1 {{8, 8, 8, 8}, 53}
  @upstream2 {{1, 1, 1, 1}, 53}
  @upstream3 {{9, 9, 9, 9}, 53}

  setup do
    # Clear ETS table for clean state between tests
    :ets.delete_all_objects(:dns_speed_tracker)
    :ok
  end

  describe "avg/1" do
    test "returns 5000 for unknown upstream (no data)" do
      unknown = {{99, 99, 99, 99}, 53}
      assert SpeedTracker.avg(unknown) == 5000
    end

    test "returns average of recorded samples" do
      SpeedTracker.record(@upstream1, 10)
      _ = :sys.get_state(SpeedTracker)

      SpeedTracker.record(@upstream1, 20)
      _ = :sys.get_state(SpeedTracker)

      SpeedTracker.record(@upstream1, 30)
      _ = :sys.get_state(SpeedTracker)

      assert SpeedTracker.avg(@upstream1) == 20
    end

    test "returns 9999 when all samples are timeouts" do
      SpeedTracker.record_timeout(@upstream1)
      _ = :sys.get_state(SpeedTracker)

      SpeedTracker.record_timeout(@upstream1)
      _ = :sys.get_state(SpeedTracker)

      assert SpeedTracker.avg(@upstream1) == 9999
    end

    test "ignores timeout samples in average calculation" do
      SpeedTracker.record(@upstream1, 100)
      _ = :sys.get_state(SpeedTracker)

      SpeedTracker.record_timeout(@upstream1)
      _ = :sys.get_state(SpeedTracker)

      SpeedTracker.record(@upstream1, 200)
      _ = :sys.get_state(SpeedTracker)

      # Average of [100, 200] = 150
      assert SpeedTracker.avg(@upstream1) == 150
    end
  end

  describe "record/2" do
    test "stores timing data retrievable via avg" do
      SpeedTracker.record(@upstream1, 42)
      _ = :sys.get_state(SpeedTracker)

      assert SpeedTracker.avg(@upstream1) == 42
    end
  end

  describe "record_timeout/1" do
    test "records timeout marker" do
      SpeedTracker.record_timeout(@upstream1)
      _ = :sys.get_state(SpeedTracker)

      # With only timeouts, avg should be 9999
      assert SpeedTracker.avg(@upstream1) == 9999
    end
  end

  describe "pick_racers/2" do
    test "returns empty list for empty upstreams" do
      assert SpeedTracker.pick_racers([]) == []
    end

    test "returns all upstreams when count >= length" do
      upstreams = [@upstream1]
      racers = SpeedTracker.pick_racers(upstreams, 2)
      assert length(racers) == 1
    end

    test "returns exactly count upstreams when more are available" do
      upstreams = [@upstream1, @upstream2, @upstream3]
      racers = SpeedTracker.pick_racers(upstreams, 2)
      assert length(racers) == 2
    end

    test "returns all upstreams when count equals length" do
      upstreams = [@upstream1, @upstream2]
      racers = SpeedTracker.pick_racers(upstreams, 2)
      assert length(racers) == 2
    end

    test "returns unique upstreams (no duplicates)" do
      upstreams = [@upstream1, @upstream2, @upstream3]
      racers = SpeedTracker.pick_racers(upstreams, 2)
      assert length(Enum.uniq(racers)) == length(racers)
    end
  end

  describe "rank/1" do
    test "sorts upstreams by average response time ascending" do
      # Record fast times for upstream1, slow for upstream2
      SpeedTracker.record(@upstream1, 10)
      _ = :sys.get_state(SpeedTracker)

      SpeedTracker.record(@upstream2, 100)
      _ = :sys.get_state(SpeedTracker)

      ranked = SpeedTracker.rank([@upstream1, @upstream2])
      [{first, first_avg}, {second, second_avg}] = ranked

      assert first == @upstream1
      assert second == @upstream2
      assert first_avg < second_avg
    end

    test "unknown upstreams get default avg of 5000" do
      unknown = {{77, 77, 77, 77}, 53}
      ranked = SpeedTracker.rank([unknown])
      assert [{^unknown, 5000}] = ranked
    end
  end

  describe "stats/0" do
    test "returns empty list when no data" do
      assert SpeedTracker.stats() == []
    end

    test "returns stats with expected fields for recorded upstream" do
      SpeedTracker.record(@upstream1, 50)
      _ = :sys.get_state(SpeedTracker)

      SpeedTracker.record(@upstream1, 100)
      _ = :sys.get_state(SpeedTracker)

      [stat] = SpeedTracker.stats()
      assert stat.upstream == @upstream1
      assert stat.avg_ms == 75
      assert stat.min_ms == 50
      assert stat.max_ms == 100
      assert stat.samples == 2
      assert stat.timeouts == 0
    end

    test "counts timeouts correctly in stats" do
      SpeedTracker.record(@upstream1, 50)
      _ = :sys.get_state(SpeedTracker)

      SpeedTracker.record_timeout(@upstream1)
      _ = :sys.get_state(SpeedTracker)

      [stat] = SpeedTracker.stats()
      assert stat.samples == 2
      assert stat.timeouts == 1
      assert stat.avg_ms == 50
    end

    test "reports nil avg/min/max when all timeouts" do
      SpeedTracker.record_timeout(@upstream1)
      _ = :sys.get_state(SpeedTracker)

      [stat] = SpeedTracker.stats()
      assert stat.avg_ms == nil
      assert stat.min_ms == nil
      assert stat.max_ms == nil
      assert stat.timeouts == 1
    end
  end
end
