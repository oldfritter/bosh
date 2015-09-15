module Bosh::Spec
  # Director information as a regular CLI user would see it.
  # State might not be necessarily in sync with what CPI thinks
  # (e.g. CPI might know about more VMs that director does).
  class Director
    def initialize(runner, waiter, agents_base_dir, director_nats_port, logger)
      @runner = runner
      @waiter = waiter
      @agents_base_dir = agents_base_dir
      @director_nats_port = director_nats_port
      @logger = logger
      @nats_recording = []
    end

    def vms(deployment_name = '', options={})
      vms_details(deployment_name, options).map do |vm_data|
        Vm.new(
          @waiter,
          vm_data[:job_index],
          vm_data[:state],
          vm_data[:cid],
          vm_data[:agent_id],
          vm_data[:ips],
          vm_data[:az],
          vm_data[:instance_id],
          vm_data[:job_name],
          vm_data[:index],
          File.join(@agents_base_dir, "agent-base-dir-#{vm_data[:agent_id]}"),
          @director_nats_port,
          @logger,
        )
      end
    end

    # vm always returns a vm
    def vm(job_name_index, options={})
      deployment_name = options.fetch(:deployment, '')
      vm = vms(deployment_name, options).detect { |vm| vm.job_name_index == job_name_index }
      vm || raise("Failed to find vm #{job_name_index}")
    end

    # wait_for_vm either returns a vm or nil after waiting for X seconds
    # (Do not add default timeout value to be more explicit in tests)
    def wait_for_vm(job_name_index, timeout_seconds, options = {})
      start_time = Time.now
      loop do
        vm = vms('', options).detect { |vm| vm.job_name_index == job_name_index }
        return vm if vm
        break if Time.now - start_time >= timeout_seconds
        sleep(1)
      end

      @logger.info("Did not find VM after waiting for #{timeout_seconds}")
      nil
    end

    def wait_for_first_available_vm(timeout = 60)
      @waiter.wait(timeout) { vms.first || raise('Must have at least 1 VM') }
    end

    def vms_vitals
      parse_table(@runner.run('vms --vitals'))
    end

    def start_recording_nats
      # have to read NATS port on main thread, or the new thread hangs on startup (?!)
      nats_uri = "nats://localhost:#{@director_nats_port}"

      Thread.new do
        EventMachine.run do
          @nats_client = NATS.connect(uri: nats_uri) do
            @nats_client.subscribe('>') do |msg, reply, sub|
              @nats_recording << [sub, msg]
            end
          end
        end
      end
    end

    def finish_recording_nats
      @nats_client.close
      EventMachine.stop
      @nats_recording
    end

    def task(id)
      output = @runner.run("task #{id}")
      failed = /Task (\d+) error/.match(output)
      return output, !failed
    end

    def kill_vm_and_wait_for_resurrection(vm)
      vm.kill_agent
      resurrected_vm = wait_for_vm(vm.job_name_index, 300)

      if vm.cid == resurrected_vm.cid
        raise "expected vm to be recreated by cids match. original: #{vm.inspect}, new: #{resurrected_vm.inspect}"
      end

      resurrected_vm
    end

    private

    def vms_details(deployment_name, options = {})
      parse_table(@runner.run("vms #{deployment_name} --details",options))
    end

    def parse_table(output)
      rows = []
      current_row = -1

      output.lines.each do |line|
        if line =~ /^\+/
          current_row += 1
        elsif line =~ /^\|/
          rows[current_row] ||= []
          rows[current_row] << line
        end
      end

      header_row = rows.shift
      return [] unless header_row

      values_row = rows.shift
      headers = {}

      header_row.each_with_index do |row_line|
        row_titles = row_line.split('|').map(&:strip)
        row_titles.each_with_index do |row_title, key|
          headers[key] ||= ""
          headers[key] += " " + row_title
        end
      end

      headers = headers.values.map { |header| header.strip.gsub(/[\(\),]/, '').downcase.tr('/ ', '_').to_sym }

      vms = values_row.map { |row| Hash[headers.zip(row.split('|').map(&:strip))] }
      vms.each do |vm|
        match_data = /(\w+)\/([0-9a-f]{8}-[0-9a-f-]{27})\s\((\d+)\)/.match(vm[:vm])
        vm[:job_name] = match_data[1]
        vm[:instance_id] = match_data[2]
        vm[:index] = match_data[3]
        vm[:job_index] = "#{match_data[1]}/#{match_data[2]}"
      end

      # collapse rows for single VM with multiple IPs
      result = []
      vms.each_with_index do |vm, i|
        if vm[:job_index].empty?
          vms[i-1][:ips] = Array(vms[i-1][:ips])
          vms[i-1][:ips] << vm[:ips]
        else
          result << vm
        end
      end

      result
    end
  end
end
