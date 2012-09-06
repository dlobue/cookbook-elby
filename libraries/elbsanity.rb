require 'rubygems'
require 'set'

begin
    require 'fog'
    FOGFOUND = true unless defined? FOGFOUND
rescue LoadError => e
    Chef::Log.warn("Fog library not found. This is fine in development environments, but it is required in production.")
    FOGFOUND = false unless defined? FOGFOUND
end

class RequirementError < RuntimeError
end


def get_live_elb_mapping(elbconn)
    if not FOGFOUND
        raise RequirementError, "Aborting: The fog library is missing!"
    end
    basket = {}
    zone_map = {}
    elbs = elbconn.describe_load_balancers().body['DescribeLoadBalancersResult']['LoadBalancerDescriptions']
    elbs.each do |elb|
        lbname = elb['LoadBalancerName']
        lb_instances = elb['Instances']
        Chef::Log.debug("Found the following instances in the #{lbname} load balancer: #{lb_instances.join(', ')}")
        basket[lbname] = lb_instances # more direct mapping of load balancer name to currently registered instances
        zone_map[lbname] = elb['AvailabilityZones']
    end
    return basket, zone_map
end

def get_elbconn(node)
    if not FOGFOUND
        raise RequirementError, "Aborting: The fog library is missing!"
    end
    creds = get_creds()
    elbconn = Fog::AWS::ELB.new(:region => node[:ec2][:region],
                                :aws_access_key_id => creds["s3_access_key"],
                                :aws_secret_access_key => creds["s3_secret_key"])
    return elbconn
end

def update_elb_zones(elbconn, node)
    if not FOGFOUND
        raise RequirementError, "Aborting: The fog library is missing!"
    end
    creds = get_creds()
    ec2 = Fog::Compute.new(:provider => 'AWS',
                           :region => node[:ec2][:region],
                           :aws_access_key_id => creds["s3_access_key"],
                           :aws_secret_access_key => creds["s3_secret_key"])

    _memoized = {}

    live_mapping, zone_map = get_live_elb_mapping(elbconn)
    live_mapping.each_pair do |elb_name,instances|
        if instances.empty?
            Chef::Log.debug("The elb #{elb_name} has no instances registered to it. going to the next elb.")
            next
        end
        req_zones = Set.new(instances) { |i|
            begin
                _memoized.has_key?(i) ? _memoized[i] : _memoized[i] = ec2.servers.get(i).availability_zone
            rescue NoMethodError => e
                Chef::Application.fatal!("Instance that no longer exists is still in ELB! #{i}")
            end
        }
        Chef::Log.debug("The instances of the #{elb_name} elb are in the following zones: #{req_zones.to_a.join(', ')}")
        cur_zones = Set.new(zone_map[elb_name])
        Chef::Log.debug("The #{elb_name} elb is configured for the following zones: #{cur_zones.to_a.join(', ')}")

        to_enable = req_zones.difference(cur_zones).to_a
        to_disable = cur_zones.difference(req_zones).to_a

        if not to_enable.empty?
            Chef::Log.info("Enabling the following zones on the #{elb_name} elb: #{to_enable.join(', ')}")
            elbconn.enable_zones(to_enable, elb_name)
        end
        if not to_disable.empty?
            Chef::Log.info("Disabling the following zones on the #{elb_name} elb: #{to_disable.join(', ')}")
            elbconn.disable_zones(to_disable, elb_name)
        end
    end
end

def update_elb_instances(node, elbconn)
    if not FOGFOUND
        raise RequirementError, "Aborting: The fog library is missing!"
    end
    updated = false
    live_mapping = get_live_elb_mapping(elbconn)
    already_configured = []
    care_about = []
    proper_mapping = {}
    identity_map = {}
    node[:deployment][:elbs].each_pair do |trait,elb_name|
        nodes = fakesearch_nodes(trait.to_s)
        proper_mapping[elb_name] = nodes unless elb_name.nil?
        care_about.concat( nodes.map { |n| n[:persist][:ec2_instance_id] } )
        identity_map.update(Hash[nodes.map {|n| [n[:persist][:ec2_instance_id], n[:persist][:fqdn]]} ])
    end

    live_mapping[0].each_pair do |elb_name,instances|
        to_deregister = []
        to_register = []
        instances.each do |instance|
            if care_about.include? instance #instance is in our deployment
                if ( proper_mapping[elb_name].nil? or
                    (proper_mapping[elb_name].select { |n|
                        n[:persist][:ec2_instance_id] == instance }).empty? )
                    Chef::Log.info("Node #{identity_map[instance]} (#{instance}) is in the wrong ELB, or shouldn't be in an elb - queueing node to be deregistered.")
                    to_deregister << instance
                else
                    already_configured.push(instance)
                end
            end
        end

        if not proper_mapping[elb_name].nil?
            proper_mapping[elb_name].each do |n|
                if (( not already_configured.include? n[:persist][:ec2_instance_id] ) and
                    n[:persist][:state] == 'available' )
                    Chef::Log.info("Node #{n[:persist][:fqdn]} (#{n[:persist][:ec2_instance_id]}) is missing from the ELB and is ready - queueing node to be registered.")
                    to_register << n[:persist][:ec2_instance_id]
                end
            end
        end

        if not to_register.empty?
            to_reg_str = (to_register.map {|i| "#{identity_map[i]} (i)" }).join(', ')
            Chef::Log.info("Registering the following instances to the ELB #{elb_name}: #{to_reg_str}")
            elbconn.register_instances(to_register, elb_name)
            updated = true
        end
        if not to_deregister.empty?
            to_dereg_str = (to_deregister.map {|i| "#{identity_map[i]} (i)" }).join(', ')
            Chef::Log.info("Deregistering the following instances from the ELB #{elb_name}: #{to_dereg_str}")
            elbconn.deregister_instances(to_deregister, elb_name)
            updated = true
        end
    end
    return updated
end

def do_elb_thing(node)
    elbconn = get_elbconn(node)
    update_elb_instances(node, elbconn)
    update_elb_zones(elbconn, node) #XXX: this makes a lot of calls on AWS. keep runs to a minimum!
end

