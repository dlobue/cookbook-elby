
ruby_block "configure_elb" do
    action :create
    block do
        do_elb_thing(node)
    end
end

