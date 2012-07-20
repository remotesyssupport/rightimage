class Chef::Resource
  include RightScale::RightImage::Helper
end


action :configure do
  ruby_block "check hypervisor" do
    block do
      raise "ERROR: you must set your hypervisor to kvm!" unless new_resource.hypervisor == "kvm"
    end
  end

  directory temp_root { recursive true }

  # Add google init script for ubuntu
  if new_resource.platform == "ubuntu"
    cookbook_file "#{guest_root}/etc/init.d/google" do
      source "google_initscript.sh"
      owner "root"
      group "root"
      mode "0755"
      action :create
      backup false
    end
  elsif new_resource.platform =~ /centos|rhel/ && new_resource.platform_version.to_f >= 6
    # Add google init script for centos (6+ only)
    cookbook_file "#{guest_root}/etc/init/google.conf" do
      source "google.conf"
      owner "root"
      group "root"
      mode "0755"
      action :create
      backup false
    end
    cookbook_file "#{guest_root}/etc/init/google_run_startup_scripts.conf" do
      source "google_run_startup_scripts.conf"
      owner "root"
      group "root"
      mode "0755"
      action :create
      backup false
    end
  else
    raise "Unsupported platform/version combination #{new_resource.platform} #{new_resource.platform_version}"
  end

  cookbook_file "#{temp_root}/google.tgz" do
    source "google.tgz"
    action :create
    backup false
  end
  bash "untar google helper and startup scripts" do
    code "tar zxvf #{temp_root}/google.tgz -C #{guest_root}/usr/share"
  end

  if new_resource.platform == "ubuntu"
    bash "Link init script to runlevels" do
      flags "-ex" 
      code <<-EOH
        guest_root=#{guest_root}
      
        # Link init script to runlevels
        chroot $guest_root ln -sf ../init.d/google /etc/rc0.d/K01google
        chroot $guest_root ln -sf ../init.d/google /etc/rc1.d/K01google
        chroot $guest_root ln -sf ../init.d/google /etc/rc6.d/K01google
        chroot $guest_root ln -sf ../init.d/google /etc/rc2.d/s99google
        chroot $guest_root ln -sf ../init.d/google /etc/rc3.d/s99google
        chroot $guest_root ln -sf ../init.d/google /etc/rc4.d/s99google
        chroot $guest_root ln -sf ../init.d/google /etc/rc5.d/s99google
      EOH
    end
  else
    # Not necessary for upstart
  end

  bash "configure for google compute" do
    flags "-ex" 
    code <<-EOH
      guest_root=#{guest_root}

      # Set HW clock to UTC
      echo "UTC" >> $guest_root/etc/adjtime

      case "#{new_resource.platform}" in
      "centos"|"rhel")
        chroot $guest_root yum -y install python-setuptools python-devel python-libs
        # Emit signal to run google_run_startup_scripts
        # Note that this comes after and replaces the /etc/rc.local written in KVM provider
        # will not work centos 5
        echo '#!/bin/bash' > $guest_root/etc/rc.local
        echo 'initctl emit --no-wait google-rc-local-has-run' >> $guest_root/etc/rc.local
        chmod 755 $guest_root/etc/rc.local
        ;;
      "ubuntu")
        chroot $guest_root apt-get -y install python-dev python-setuptools
        chroot $guest_root apt-get -y install acpid dhcp3-client
        # Emit signal to run google_run_startup_scripts
        # Note that this comes after and replaces the /etc/rc.local written in KVM provider
        echo '#!/bin/bash' > $guest_root/etc/rc.local
        echo 'initctl emit --no-wait google-rc-local-has-run' >> $guest_root/etc/rc.local
        chmod 755 $guest_root/etc/rc.local
        # Google disables loading of kernel modules
        echo '' > /etc/modules
        ;;
      esac

      set +e 
      # Add metadata alias
      grep -E 'metadata' /etc/hosts &> /dev/null
      if [ "$?" != "0" ]; then
        echo '169.254.169.254 metadata.google.internal metadata' >> $guest_root/etc/hosts
      fi
      set -e

      # Install Boto (for gsutil)
      chroot $guest_root easy_install pip
      chroot $guest_root pip install boto

      wget http://dl.google.com/dl/compute/gcutil.tar.gz
      tar zxvf gcutil.tar.gz -C $guest_root/usr/local
      echo 'export PATH=$PATH:/usr/local/gcutil' > $guest_root/etc/profile.d/gcutil.sh

      # Install GSUtil
      wget http://commondatastorage.googleapis.com/pub/gsutil.tar.gz
      tar zxvf gsutil.tar.gz -C $guest_root/usr/local
      echo 'export PATH=$PATH:/usr/local/gsutil' > $guest_root/etc/profile.d/gsutil.sh
    EOH
  end
end

action :package do
  file "#{target_raw_root}/disk.raw" do
    action :delete
    backup false
  end
  # Chef file resource doesn't do this correctly for some reason
  bash "hard link to disk.raw" do
    cwd target_raw_root
    code "ln #{loopback_file(true)} disk.raw"
  end
  bash "zipping raw file" do
    cwd target_raw_root
    code "tar zcvf #{new_resource.image_name}.tar.gz disk.raw"
  end
end

action :upload do
  case node[:platform]
  when "centos", "redhat" then
    # Need to use yum_package instead of package or else setuptools will error out
    # with "no candidate found" because its a noarch package which package doesn't
    # understand
    %w(python-setuptools python-devel python-libs).each { |p| yum_package p }
  when "ubuntu" then
    %w(python-dev python-setuptools).each {|p| package p}
  end

  # requirement for gsutil
  bash "install boto" do
    flags "-ex"
    code <<-EOF
      export PATH=$PATH:/usr/local/bin
      easy_install -U distribute
      easy_install pip
      pip install boto
    EOF
  end

  bash "install gcutil" do
    creates "/usr/local/gcutil/gcutil"
    code <<-EOF
  wget http://dl.google.com/dl/compute/gcutil.tar.gz
  tar zxvf gcutil.tar.gz -C /usr/local
  echo 'export PATH=$PATH:/usr/local/gcutil' > /etc/profile.d/gcutil.sh
  source /etc/profile.d/gcutil.sh
EOF
  end

  bash "install gsutil" do
    creates "/usr/local/gsutil/gsutil"
    code <<-EOF
  wget http://commondatastorage.googleapis.com/pub/gsutil.tar.gz
  tar zxvf gsutil.tar.gz -C /usr/local
  echo 'export PATH=$PATH:/usr/local/gsutil' > /etc/profile.d/gsutil.sh
  source /etc/profile.d/gsutil.sh
EOF
  end
 
  # TBD, replace this block. We use the gsutil/gcutil tools to do this, but we 
  # need to generate the refresh_token on another computer (see rightimage_tools/google_token)
  # We can skip this and use the api directly with the "service accounts" oauth method
  # but these tools don't support that control flow and need to look into doing
  # it with google-api-python or google-api-ruby separately. don't think those tools
  # work yet either, revisit later 
  template "/root/.gcutil_auth" do
    source "gcutil_auth.erb"
    variables(
      :client_id => node[:rightimage][:google][:client_id],
      :client_secret => node[:rightimage][:google][:client_secret],
      :refresh_token => node[:rightimage][:google][:refresh_token]
    )
    backup false
  end

  template "/root/.boto" do 
    source "google_boto.erb"
    variables(
      :gc_access_key_id     => node[:rightimage][:google][:gc_access_key_id],
      :gc_secret_access_key => node[:rightimage][:google][:gc_secret_access_key]
    )
    backup false
  end

  bash "upload image" do
    image = "#{target_raw_root}/#{new_resource.image_name}.tar.gz"
    code <<-EOF
      if [ ! -e #{image} ]; then
        echo "ERROR: file #{image} does not exist, aborting upload!"
        exit 1
      fi
      /usr/local/gsutil/gsutil cp #{image} gs://#{node[:rightimage][:image_upload_bucket]}/
    EOF
  end

  bash "register image" do
    flags "-ex"
    code <<-EOF
#      echo "Image registration not supported yet, register image with command: "
#      echo "gcutil addimage #{new_resource.image_name} http://commondatastorage.googleapis.com/#{node[:rightimage][:image_upload_bucket]}/#{new_resource.image_name}.tar.gz --project_id=#{node[:rightimage][:google][:project_id]}"

      /usr/local/gcutil/gcutil addimage #{new_resource.image_name} \
      "http://commondatastorage.googleapis.com/#{node[:rightimage][:image_upload_bucket]}/#{new_resource.image_name}.tar.gz" \
      --project_id=#{node[:rightimage][:google][:project_id]}
    EOF
  end

#  ruby_block "store id" do
    # add to global id store for use by other recipes
#    id_list = RightImage::IdList.new(Chef::Log)
#    id_list.add(image_id)
#  end
end
