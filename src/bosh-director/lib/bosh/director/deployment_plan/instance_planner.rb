module Bosh
  module Director
    module DeploymentPlan
      class InstancePlanner
        def initialize(instance_plan_factory, logger)
          @instance_plan_factory = instance_plan_factory
          @logger = logger
        end

        def plan_instance_group_instances(instance_group, desired_instances, existing_instance_models, vm_resources_cache)
          if existing_instance_models.count(&:ignore) > 0
            fail_if_specifically_changing_state_of_ignored_vms(instance_group, existing_instance_models)
          end

          network_planner = NetworkPlanner::Planner.new(@logger)
          placement_plan = PlacementPlanner::Plan.new(@instance_plan_factory, network_planner, @logger)
          vip_networks, non_vip_networks = instance_group.networks.to_a.partition(&:vip?)
          instance_plans = placement_plan.create_instance_plans(desired_instances, existing_instance_models, non_vip_networks, instance_group.availability_zones, instance_group.name)

          log_outcome(instance_plans)

          desired_instance_plans = instance_plans.reject(&:obsolete?)
          NetworkPlanner::VipPlanner.new(network_planner, @logger).add_vip_network_plans(desired_instance_plans, vip_networks)

          elect_bootstrap_instance(desired_instance_plans)
          update_instance_cloud_properties(vm_resources_cache, desired_instance_plans, instance_group.vm_resources.spec) if instance_group.vm_resources
          instance_plans
        end

        def plan_obsolete_instance_groups(desired_instance_groups, existing_instances)
          desired_instance_group_names = Set.new(desired_instance_groups.map(&:name))
          migrating_instance_group_names = Set.new(desired_instance_groups.map(&:migrated_from).flatten.map(&:name))
          obsolete_existing_instances = existing_instances.reject do |existing_instance_model|
            desired_instance_group_names.include?(existing_instance_model.job) ||
              migrating_instance_group_names.include?(existing_instance_model.job)
          end

          obsolete_existing_instances.each do |instance_model|
            next unless instance_model.ignore

            raise DeploymentIgnoredInstancesDeletion, 'You are trying to delete instance group ' \
              "'#{instance_model.job}', which " \
              'contains ignored instance(s). Operation not allowed.'
          end

          obsolete_existing_instances.map do |obsolete_existing_instance|
            @instance_plan_factory.obsolete_instance_plan(obsolete_existing_instance)
          end
        end

        def orphan_unreusable_vms(instance_plans, existing_instance_models)
          desired_instance_plans = instance_plans.reject(&:obsolete?)
          existing_instance_models.each do |instance_model|
            orphaned = false

            instance_model.vms.each do |candidate_vm|
              next if candidate_vm.active
              next if desired_instance_plans.any? do |desired_instance|
                desired_instance.vm_matches_plan?(candidate_vm)
              end

              orphaned = true

              Steps::OrphanVmStep.new(candidate_vm).perform(nil)
            end

            instance_model.reload if orphaned
          end
        end

        def reconcile_network_plans(instance_plans)
          instance_plans.each do |instance_plan|
            next if instance_plan.obsolete?

            network_plans = NetworkPlanner::ReservationReconciler.new(
              instance_plan,
              @logger,
            ).reconcile(instance_plan.instance.existing_network_reservations)

            instance_plan.network_plans = network_plans
          end
        end

        private

        def update_instance_cloud_properties(vm_resources_cache, instance_plans, vm_resources)
          instance_plans.each do |instance_plan|
            vm_cloud_properties = vm_resources_cache.get_vm_cloud_properties(
              instance_plan.instance.availability_zone&.cpi,
              vm_resources,
            )
            instance_plan.instance.update_vm_cloud_properties(vm_cloud_properties)
          end
        end

        def elect_bootstrap_instance(desired_instance_plans)
          bootstrap_instance_plans = desired_instance_plans.select { |i| i.instance.bootstrap? }

          if bootstrap_instance_plans.size == 1
            bootstrap_instance_plan = bootstrap_instance_plans.first

            instance = bootstrap_instance_plan.instance
            @logger.info("Found existing bootstrap instance '#{instance}' in az '#{bootstrap_instance_plan.desired_instance.availability_zone}'")
          else
            return if desired_instance_plans.empty?

            if bootstrap_instance_plans.size > 1
              @logger.info('Found multiple existing bootstrap instances. Going to pick a new bootstrap instance.')
            else
              @logger.info('No existing bootstrap instance. Going to pick a new bootstrap instance.')
            end
            lowest_indexed_desired_instance_plan = desired_instance_plans
                                                   .reject { |instance_plan| instance_plan.desired_instance.index.nil? }
                                                   .min_by { |instance_plan| instance_plan.desired_instance.index }

            desired_instance_plans.each do |instance_plan|
              instance = instance_plan.instance
              if instance_plan == lowest_indexed_desired_instance_plan
                @logger.info("Marking new bootstrap instance '#{instance}' in az '#{instance_plan.desired_instance.availability_zone}'")
                instance.mark_as_bootstrap
              else
                instance.unmark_as_bootstrap
              end
            end
          end
        end

        def fail_if_specifically_changing_state_of_ignored_vms(instance_group, existing_instance_models)
          ignored_models = existing_instance_models.select(&:ignore)
          ignored_models.each do |model|
            next if instance_group.instance_states[model.index.to_s].nil?

            raise JobInstanceIgnored, 'You are trying to change the state of the ignored instance ' \
              "'#{model.job}/#{model.uuid}'. " \
              'This operation is not allowed. You need to unignore it first.'
          end
        end

        def log_outcome(instance_plans)
          instance_plans.select(&:new?).each do |instance_plan|
            desired_instance = instance_plan.desired_instance
            @logger.info("New desired instance '#{desired_instance.instance_group.name}/#{desired_instance.index}' in az '#{desired_instance.availability_zone}'")
          end

          instance_plans.select(&:existing?).each do |instance_plan|
            instance = instance_plan.existing_instance
            vm_activeness_msg = instance.active_vm ? 'active vm' : 'no active vm'
            @logger.info('Existing desired instance ' \
              "'#{instance.job}/#{instance.index}' in az " \
              "'#{instance_plan.desired_instance.availability_zone}' " \
              "with #{vm_activeness_msg}")
          end

          instance_plans.select(&:obsolete?).each do |instance_plan|
            instance = instance_plan.existing_instance
            @logger.info("Obsolete instance '#{instance.job}/#{instance.index}' in az '#{instance.availability_zone}'")
          end
        end
      end
    end
  end
end
