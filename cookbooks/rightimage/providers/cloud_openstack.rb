action :configure do 
  
  bash "install guest packages" do 
    flags '-ex'
    code <<-EOH
  case "#{new_resource.platform}" in
    "centos"|"rhel")
      chroot #{guest_root} yum -y install iscsi-initiator-utils
      ;;
  esac
    EOH
  end

  # insert grub conf, and link menu.lst to grub.conf
  directory "#{guest_root}/boot/grub" do
    owner "root"
    group "root"
    mode "0750"
    action :create
    recursive true
  end 

  # insert grub conf, and symlink
  template "#{guest_root}/boot/grub/menu.lst" do
    source "menu.lst.erb"
    backup false 
  end

  Chef::Log::info "Add DHCP symlink for RightLink"
  execute "chroot #{guest_root} ln -s /var/lib/dhcp /var/lib/dhcp3" do
    only_if { ::File.exists?"#{guest_root}/var/lib/dhcp" }
    creates "#{guest_root}/var/lib/dhcp3"
  end

  bash "setup grub" do
    not_if { new_resource.hypervisor == "xen" }
    flags "-ex"
    code <<-EOH
      guest_root="#{guest_root}"
      
      case "#{new_resource.platform}" in
        "ubuntu")
          chroot $guest_root cp -p /usr/lib/grub/x86_64-pc/* /boot/grub
          grub_command="/usr/sbin/grub"
          ;;
        "centos"|"rhel")
          chroot $guest_root cp -p /usr/share/grub/x86_64-redhat/* /boot/grub
          grub_command="/sbin/grub"
          ;;
      esac

      echo "(hd0) #{node[:rightimage][:grub][:root_device]}" > $guest_root/boot/grub/device.map
      echo "" >> $guest_root/boot/grub/device.map

      cat > device.map <<EOF
(hd0) #{loopback_file(partitioned?)}
EOF

    ${grub_command} --batch --device-map=device.map <<EOF
root (hd0,0)
setup (hd0)
quit
EOF
EOH
  end
  
  bash "configure for openstack" do
    flags "-ex"
    code <<-EOH
      guest_root=#{guest_root}

      case "#{node[:rightimage][:platform]}" in
      "centos"|"rhel")
        # clean out packages
        chroot $guest_root yum -y clean all

        # clean centos RPM data
        rm ${guest_root}/var/lib/rpm/__*
        chroot $guest_root rpm --rebuilddb

        # enable console access
        if [ -f $guest_root/etc/sysconfig/init ]; then
          sed -i "s/ACTIVE_CONSOLES=.*/ACTIVE_CONSOLES=\\/dev\\/tty1/" $guest_root/etc/sysconfig/init
        else
          echo "2:2345:respawn:/sbin/mingetty tty2" >> $guest_root/etc/inittab
          echo "tty2" >> $guest_root/etc/securetty
        fi

        # configure dhcp timeout
        echo 'timeout 300;' > $guest_root/etc/dhclient.conf

        [ -f $guest_root/var/lib/rpm/__* ] && rm ${guest_root}/var/lib/rpm/__*
        chroot $guest_root rpm --rebuilddb
        ;;
      "ubuntu")
        # Disable all ttys except for tty1 (console)
        for i in `ls $guest_root/etc/init/tty[2-9].conf`; do
          mv $i $i.disabled;
        done
        ;;
      esac

      # set hwclock to UTC
      echo "UTC" >> $guest_root/etc/adjtime
    EOH
  end
end

action :package do
  rightimage_image node[:rightimage][:image_type] do
    action :package
  end
end

action :upload do
  packages = case node[:platform]
             when "centos", "redhat" then
               if node[:platform_version].to_f >= 6.0
                 %w(python-setuptools python-devel python-libs)
               else
                 %w(python26-distribute python26-devel python26-libs)
               end
             when "ubuntu" then
               %w(python-dev python-setuptools)
             end

  packages.each { |p| package p }

  # Switched from easy_install to pip for most stuff, easy_install seems to be
  # crapping out complaining about fetching from git urls while pip handles them fine
  # Also pip handles all the dependencies better - PS
  bash "install python modules" do
    flags "-ex"
    cmd_append = ""
    if node[:platform] =~ /centos|rhel/ && node[:platform_version].to_f < 6.0
      cmd_append = "-2.6"
    end
    code <<-EOH
      export PATH=$PATH:/usr/local/bin
      easy_install#{cmd_append} pip
      easy_install#{cmd_append} -U distribute
      pip#{cmd_append} install glance
    EOH
  end

  ruby_block "upload to cloud" do
    block do
      require 'json'
      filename = "#{image_name}.qcow2"
      local_file = "#{target_raw_root}/#{filename}"

      openstack_user = node[:rightimage][:openstack][:user]
      openstack_password = node[:rightimage][:openstack][:password]
      openstack_host = node[:rightimage][:openstack][:hostname].split(":")[0]
      openstack_api_port = node[:rightimage][:openstack][:hostname].split(":")[1] || "5000"
      openstack_glance_port = "9292"

      Chef::Log.info("Getting openstack api token for user #{openstack_user}@#{openstack_host}:#{openstack_api_port}")
      auth_resp = `curl -d '{"auth":{"passwordCredentials":{"username": "#{openstack_user}", "password": "#{openstack_password}"}}}' -H "Content-type: application/json" http://#{openstack_host}:#{openstack_api_port}/v2.0/tokens` 
      Chef::Log.info("got response for auth req: #{auth_resp}")
      auth_hash = JSON.parse(auth_resp)
      access_token = auth_hash["access"]["token"]["id"]

      # Don't use location=file://path/to/file like you might think, thats the name of the location to store the file on the server that hosts the images, not this machine
      cmd = %Q(env PATH=$PATH:/usr/local/bin glance add --auth_token=#{access_token} --url=http://#{openstack_host}:#{openstack_glance_port}/v2.0 name=#{image_name} is_public=true disk_format=qcow2 container_format=ovf < #{local_file})
      Chef::Log.debug(cmd)
      upload_resp = `#{cmd}`
      Chef::Log.info("got response for upload req: #{upload_resp} to cloud.")

      if upload_resp =~ /added/i 
        image_id = upload_resp.scan(/ID:\s(\d+)/i).first
        Chef::Log.info("Successfully uploaded image #{image_id} to cloud.")
        
        # add to global id store for use by other recipes
        id_list = RightImage::IdList.new(Chef::Log)
        id_list.add(image_id)
      else
        raise "ERROR: could not upload image to cloud at #{node[:rightimage][:openstack][:hostname]} due to #{upload_resp.inspect}"
      end
    end
  end
end
