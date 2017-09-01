defmodule Cingi.CLI do
	def main(args) do
		Process.register self(), :local_cli
		args |> parse_args |> process
	end

	def process([]) do
		IO.puts "No arguments given"
	end

	def process(options) do
		Cingi.Branch.link_cli(:local_branch, self())
		mbn = options[:minbranches]
		connect_to = options[:connectto]
		connect_or_headquarters(connect_to, mbn, options)
	end

	def connect_or_headquarters(nil, min_branch_num, options) do
		min_branch_num = min_branch_num || 0
		Cingi.Headquarters.start_link(name: {:global, :hq})
		Cingi.Headquarters.link_branch({:global, :hq}, :local_branch)

		set_up_network(min_branch_num, options)
		wait_for_branches(min_branch_num - 1)
		start_missions(options[:file])
	end

	def connect_or_headquarters(host, nil, options) do
		set_up_network(true, options)
		host = String.to_atom host
		wait_for_hq(host)
		Cingi.Headquarters.link_branch({:global, :hq}, :local_branch)
		IO.puts "Connected local branch to global headquarters"
		Process.send({:local_cli, host}, {:branch_connect, self()}, [])

		Node.monitor host, true
		receive do
			{:nodedown, _} -> :error
			_ -> :ok
		end
	end

	def connect_or_headquarters(_, _, _) do
		raise "Cannot have both connect_to and min_branch_num options"
	end

	def start_missions(nil) do
	end

	def start_missions(file) do
		yaml_opts = [file: file, cli_pid: self()]
		Cingi.Branch.create_report :local_branch, yaml_opts
		receive do
			{:report, _} -> :ok
		end
	end

	defp parse_args(args) do
		{options, _, _} = OptionParser.parse(args,
			switches: [
				minbranches: :integer,
				file: :string,
				connectto: :string,
			]
		)
		options
	end

	def wait_for_branches(countdown) do
		case countdown do
			n when n <= 0 -> :ok
			n ->
				IO.puts "Waiting for #{n} branches to connect"
				receive do
					{:branch_connect, _} -> wait_for_branches(n - 1)
				end
		end
	end

	def set_up_network(0, _) do end

	def set_up_network(_, options) do
		case {options[:name], options[:cookie]} do
			{nil, nil} -> raise "Requires name and cookie for networking"
			{nil, _} -> raise "Requires name for networking"
			{_, nil} -> raise "Requires cookie for networking"
			{name, cookie} ->
				Node.start(String.to_atom(name), :shortnames)
				Node.set_cookie(String.to_atom(cookie))
		end
	end

	def wait_for_hq(host, countdown \\ 100) do
		Node.connect(host)
		case GenServer.whereis({:global, :hq}) do
			nil ->
				Process.sleep 100
				case countdown do
					n when n <= 0 -> raise "Took too long connecting to headquarters"
					n -> wait_for_hq(host, n - 1)
				end
			_ -> Cingi.Headquarters.get({:global, :hq})
		end
	end
end
