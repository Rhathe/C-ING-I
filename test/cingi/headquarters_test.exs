defmodule CingiHeadquartersTest do
	use ExUnit.Case
	alias Cingi.Headquarters
	alias Cingi.Outpost
	alias Cingi.Mission
	alias Cingi.MissionReport
	doctest Headquarters

	test "creates headquarters" do
		{:ok, pid} = Headquarters.start_link()
		assert %{
			running: true,
			mission_reports: [],
			queued_missions: [],
			running_missions: [],
			finished_missions: []
		} = Headquarters.get(pid)
	end

	test "can pause headquarters" do
		pid = get_paused()
		assert %{running: false} = Headquarters.get(pid)
	end

	defp create_mission_report(opts) do
		pid = get_paused()
		report_pid = Headquarters.create_report(pid, opts)
		hq = Headquarters.get(pid)
		mission_pid = Enum.at(hq.queued_missions, 0)

		[
			hq: hq,
			report: MissionReport.get(report_pid),
			mission: Mission.get(mission_pid),
			pid: pid,
			report_pid: report_pid,
			mission_pid: mission_pid
		]
	end

	test "can create mission report" do
		res = create_mission_report([string: "missions: echo 1"])
		assert %{"missions" => "echo 1"} = res[:report].plan
		assert res[:report_pid] in res[:hq].mission_reports
	end

	test "creating mission report queued mission" do
		res = create_mission_report([string: "missions: echo 1"])
		assert length(res[:hq].queued_missions) == 1
		assert res[:mission].cmd == "echo 1"
	end

	test "runs queued missions" do
		res = create_mission_report([string: "missions: echo 1"])
		pid = res[:pid]
		mpid = res[:mission_pid]
		Headquarters.resume(pid)
		Helper.check_exit_code mpid

		hq = wait_for_finished_missions(pid, 1)
		assert length(hq.queued_missions) == 0
		assert length(hq.finished_missions) == 1
		mission = wait_for_exit_code(res[:mission_pid])
		assert [[data: "1\n", type: :out, timestamp: _, pid: []]] = mission.output
	end

	test "runs missions with outputs" do
		cmd_1 = "  - echo -e \"match1\\nignored2\\nmatch3\""
		grep_cmd = "  - missions: grep match\n    input: $IN"

		res = create_mission_report([string: "\nmissions:\n#{cmd_1}\n#{grep_cmd}\n  - echo end"])
		pid = res[:pid]
		Headquarters.resume(pid)
		mission = wait_for_exit_code(res[:mission_pid])

		outputs = mission.output
			|> Enum.map(&(String.split(&1[:data], "\n", trim: true)))
			|> List.flatten

		assert ["match1", "ignored2", "match3", "match1", "match3", "end"] = outputs
	end

	test "runs sequential submissions" do
		yaml = "missions:\n  - ncat -l -i 1 8000\n  - ncat -l -i 1 8001"
		res = create_mission_report([string: yaml])
		pid = res[:pid]
		Headquarters.resume(pid)

		hq = wait_for_running_missions(pid, 2)
		assert length(hq.queued_missions) == 0
		assert length(hq.running_missions) == 2
		assert length(hq.finished_missions) == 0

		mission = Mission.get(res[:mission_pid])
		assert %{output: [], exit_code: nil, submission_pids: [sm1]} = mission
		submission1 = Mission.get(sm1)
		assert %{cmd: "ncat -l -i 1 8000", running: true, finished: false} = submission1

		Porcelain.spawn("bash", [ "-c", "echo -n blah1 | nc localhost 8000"])
		wait_for_finished_missions(pid, 1)
		hq = wait_for_running_missions(pid, 2)
		assert length(hq.queued_missions) == 0
		assert length(hq.running_missions) == 2
		assert length(hq.finished_missions) == 1

		mission = Mission.get(res[:mission_pid])
		assert %{output: output, exit_code: nil, submission_pids: [sm1, sm2]} = mission
		assert [[data: "blah1", type: :out, timestamp: _, pid: [^sm1]]] = output

		submission1 = Mission.get(sm1)
		submission2 = Mission.get(sm2)

		assert %{cmd: "ncat -l -i 1 8000", running: false, finished: true} = submission1
		assert %{cmd: "ncat -l -i 1 8001", running: true, finished: false} = submission2

		Porcelain.spawn("bash", [ "-c", "echo -n blah2 | nc localhost 8001"])
		mission = wait_for_exit_code(res[:mission_pid])

		assert %{output: output, exit_code: 0} = mission
		assert [
			[data: "blah1", type: :out, timestamp: _, pid: [^sm1]],
			[data: "blah2", type: :out, timestamp: _, pid: [^sm2]]
		] = output

		submission2 = Mission.get(sm2)
		assert %{cmd: "ncat -l -i 1 8001", running: false, finished: true} = submission2

		hq = wait_for_finished_missions(pid, 3)
		assert length(hq.queued_missions) == 0
		assert length(hq.running_missions) == 0
		assert length(hq.finished_missions) == 3
	end

	test "runs parallel submissions" do
		yaml = Enum.map [1,2,3,4], &("  s#{&1}: ncat -l -i 1 900#{&1}")
		yaml = ["missions:"] ++ yaml
		yaml = Enum.join yaml, "\n"

		res = create_mission_report([string: yaml])
		pid = res[:pid]
		Headquarters.resume(pid)

		hq = wait_for_running_missions(pid, 5)
		assert length(hq.queued_missions) == 0
		assert length(hq.running_missions) == 5

		finish = &(Porcelain.spawn("bash", [ "-c", "echo -n blah#{&1} | nc localhost 900#{&1}"]))

		finish.(3)
		wait_for_submissions_finish(res[:mission_pid], 1)
		finish.(2)
		wait_for_submissions_finish(res[:mission_pid], 2)
		finish.(4)
		wait_for_submissions_finish(res[:mission_pid], 3)
		finish.(1)
		wait_for_submissions_finish(res[:mission_pid], 4)

		mission = wait_for_exit_code(res[:mission_pid])
		assert %{output: [
			[data: "blah3", type: :out, timestamp: _, pid: [pid1]],
			[data: "blah2", type: :out, timestamp: _, pid: [pid2]],
			[data: "blah4", type: :out, timestamp: _, pid: [pid3]],
			[data: "blah1", type: :out, timestamp: _, pid: [pid4]]
		], exit_code: 0} = mission

		assert pid1 != pid2 != pid3 != pid4
		assert pid1 in mission.submission_pids
		assert pid2 in mission.submission_pids
		assert pid3 in mission.submission_pids
		assert pid4 in mission.submission_pids
	end

	test "runs example file" do
		res = create_mission_report([file: "test/mission_plans/example1.plan"])
		pid = res[:pid]
		Headquarters.resume(pid)
		mission = wait_for_exit_code(res[:mission_pid])
		output = mission.output |> Enum.map(&(&1[:data]))
		assert ["beginning\n", a, b, c, d, e, f, grepped, "end\n"] = output

		l1 = Enum.sort(["match 1\n", "ignored 2\n", "match 3\n", "ignored 4\n", "match 5\n", "ignored 6\n"])
		l2 = Enum.sort([a, b, c, d, e, f])
		assert ^l1 = l2

		matches = grepped |> String.split("\n") |> Enum.sort
		assert length(matches) == 4
		match_check = Enum.sort(["match 1", "match 3", "match 5", ""])
		assert ^match_check = matches
	end

	test "make sure inputs are passed correctly to nested missions" do
		res = create_mission_report([file: "test/mission_plans/nested.plan"])
		pid = res[:pid]
		Headquarters.resume(pid)
		mission = wait_for_exit_code(res[:mission_pid])
		output = mission.output |> Enum.map(&(&1[:data]))
		assert [
			"blah1\n",
			"blah1\n",
			"1match1\n",
			"2match2\n",
			"1match3\n",
			"2match1\n",
			"ignored\n",
			"1match4\n",
			"2match5\n",
			"1match1\n2match2\n1match3\n2match1\n1match4\n2match5\n",
			"2match2\n2match1\n2match5\n",
			a,
			b,
		] = output

		sublist = [a, b]
		assert "2match1\n" in sublist
		assert "2match5\n" in sublist
	end

	test "generates correct outposts" do
		res = create_mission_report([file: "test/mission_plans/outposts.plan"])
		pid = res[:pid]
		mpid = res[:mission_pid]
		Headquarters.resume(pid)
		Helper.check_exit_code mpid

		opids = Headquarters.get(pid).finished_missions
			|> Enum.map(&Mission.get_outpost/1)
			|> Enum.uniq

		assert length(opids) == 2
		outposts = opids |> Enum.map(&Outpost.get/1)

		assert %{
			alternates: _,
			node: :nonode@nohost,
		} = Enum.at(outposts, 0)
	end

	test "gets correct exit codes fails fast when necessary" do
		res = create_mission_report([file: "test/mission_plans/exits.plan"])
		pid = res[:pid]
		mpid = res[:mission_pid]
		Headquarters.resume(pid)

		hq = wait_for_finished_missions(pid, 11)
		assert length(hq.queued_missions) == 0

		# non-fail fast ncat task, its parent,
		# the whole parallel mission, and the mission itself
		assert length(hq.running_missions) == 4

		# 1 sequential supermission
		# 2 submissions below that
		# 4 sequential missions (fail_fast doesn't matter with sequential)
		# 1 fail fast parallel supermission
		# 2 fail fast parallel missions
		# 1 non-fail fast parallel mission
		assert length(hq.finished_missions) == 11

		Porcelain.exec("bash", [ "-c", "echo -n endncat | ncat localhost 9991"])
		Helper.check_exit_code mpid

		mission = Mission.get(mpid)
		assert 137 = mission.exit_code

		output = mission.output |>
			Enum.map(&(&1[:data]))

		assert [a, b, "endncat"] = output
		l1 = Enum.sort(["seq_continue\n", "seq_fail_fast\n"])
		assert ^l1 = Enum.sort([a, b])
	end

	defp get_paused() do
		{:ok, pid} = Headquarters.start_link()
		Headquarters.pause(pid)
		pid
	end

	defp wait_for_exit_code(pid) do
		mission = Mission.get(pid)
		case mission.exit_code do
			nil -> wait_for_exit_code(pid)
			_ -> mission
		end
	end

	defp wait_for_running_missions(pid, n) do
		hq = Headquarters.get(pid)
		cond do
			n <= length(hq.running_missions) -> hq
			true -> wait_for_running_missions(pid, n)
		end
	end

	defp wait_for_finished_missions(pid, n) do
		hq = Headquarters.get(pid)
		cond do
			n <= length(hq.finished_missions) -> hq
			true -> wait_for_finished_missions(pid, n)
		end
	end

	defp wait_for_submissions_finish(pid, n) do
		mission = Mission.get(pid)
		pids = mission.submission_pids
		sum = length(Enum.filter(pids, &(not is_nil(Mission.get(&1).exit_code))))
		cond do
			n <= sum -> mission
			true -> wait_for_submissions_finish(pid, n)
		end
	end
end
