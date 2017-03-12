require 'json'
require 'rubygems'
require 'aws-sdk'
require 'time'

class GetVersions

  SSM_DOCUMENT_DESC = 'Get version of Pugme Amazon Linux'

  def initialize(options = {})

    @account        = options[:account]
    @environment    = options[:environment]
    @profile        = options[:profile] ||= @account

    @s3_bucket_name = options[:s3_bucket_name] ||= 'pugme.ssm.dev'
    @s3_bucket_pfx  = options[:s3_bucket_pfx]  ||= @account
    @ssm_document   = options[:ssm_document]   ||= 'get_versions'
    @region         = options[:region]         ||= 'eu-west-1'
    @debug          = options[:debug]          ||= false
    @ssm_doc_name   = options[:ssm_doc_name]   ||= 'get_versions'

    @base_param_key = options[:base_param_key] ||= 'base-version'

    @client = Aws::SSM::Client.new(
      profile: @profile,
      region:  @region,
    )

  end

=begin
  Get SSM Association ID using targets filter

  Args:
    environment
  Returns:
    association_id
=end

  def get_association_id(environment = @environment)
    # You cannot filter by targets, but you can use the document name
    filter = {
      association_filter_list: [
        {
          key: "Name",
          value: "#{ @ssm_doc_name }",
        },
      ],
      max_results: 1
    }

    association = @client.list_associations(filter).associations.select {|a|
      a.targets[0].key.eql?('tag:Environment') && a.targets[0].values[0].eql?(@environment)
    }
    puts association.inspect if @debug
    @association_id = association.first.association_id

  end

  def get_association_status

=begin

  Get Association Status

  Returns:
    status
=end

    request = {
      association_id: @association_id
    }

    resp = @client.describe_association(request)
    return resp.association_description.overview.status
  end

  def get_instances_from_inventory()
     @inventory = @client.get_inventory()
  end

=begin

  Update the prefix of the S3 bucket output location for the supplied
  Association ID. This can be useful for limiting the number of objects in
  a Bucket by setting the prefix to YYYY-MM-DD

  Args:
    pfx: S3 Bucket Prefix
    association_id: SSM Association ID

=end
  def update_association_output_s3_key_prefix(pfx, association_id = @association_id)

    request = {
      :association_id        => @association_id,
      :output_location       => {
        :s3_location         => {
          :output_s3_region      => @region,
          :output_s3_bucket_name => @s3_bucket_name,
          :output_s3_key_prefix  => pfx,
        }
      }
    }

    resp = @client.update_association(request)

    until get_association_status.eql?('Success') do
      sleep(2)
      puts "Waiting for successful association status"
    end

    puts resp.inspect if @debug

  end


=begin
  Get value from SSM Parameter store

  Args:
    key_name

=end

  def get_parameter(key_name = @base_param_key)

    request = {
      names: [key_name], # required
      with_decryption: false,
    }

    @base_version = @client.get_parameters(request).parameters[0].value
    puts "Parameter #{key_name} has value #{ @base_version }"
  end

  def send_refresh(association_id = @association_id)

    # No need to output to S3 Bucket, nothing to see
    # and duplicated in console
    request = {
      :document_name         => 'AWS-RefreshAssociation',
      :comment               => 'Refresh Assocation',
      :targets               => [
        {
          "key" => "tag:Environment",
          "values" => [@environment]
        }
      ],
      :parameters            => {
        :associationIds => [ association_id ]
      }
    }

    resp = @client.send_command(request)

    puts resp.inspect if @debug

  end

  def send_command_by_instances()

    instance_ids = @inventory.entities.map {|i| i.id }

    # Arse, we might have an issue here seems like
    # the API might only accept a single instance id
    request = {
      :document_name         => @ssm_document,
      :comment               => SSM_DOCUMENT_DESC,
      :targets               => [
        {
          "key" => "instanceids",
          "values" => ["i-085553375ff1887b2"]
        }
      ],
      :output_s3_region      => @region,
      :output_s3_bucket_name => @s3_bucket_name,
      :output_s3_key_prefix  => @s3_bucket_pfx,
    }

    puts request.inspect if @debug

    resp = @client.send_command(request)
    # block until state transition to completed || failed

    @command_id = resp.command.command_id
    # Disappointing, there's no waiters implemented for SSM yet
    # https://github.com/aws/aws-sdk-ruby/issues/1185
    # puts @client.waiter_names
  end

  def send_command_by_tag()

    request = {
      :document_name         => @ssm_document,
      :comment               => SSM_DOCUMENT_DESC,
      :targets               => [
        {
          "key" => "tag:Environment",
          "values" => [@environment]
        }
      ],
      :output_s3_region      => @region,
      :output_s3_bucket_name => @s3_bucket_name,
      :output_s3_key_prefix  => @s3_bucket_pfx,
    }

    resp = @client.send_command(request)

    @command_id = resp.command.command_id

  end

  def get_invocation_detail(instance_id, command_id = @command_id)

    request = {
      :command_id  => command_id,
      :instance_id => instance_id
    }

    puts request if @debug

    invocation = @client.get_command_invocation(request)

    puts invocation.inspect if @debug

    return invocation

  end

  def get_data_from_command_invocations(command_id = @command_id)

    request = {
      :command_id => command_id,
      :details    => true
    }

    invocations = @client.list_command_invocations(request)

    puts invocations.inspect if @debug

    # Again no waiter in the SDK
    invocations.command_invocations.each do |i|
      if i.status.eql?('Success')
        puts "Instance #{ i.instance_id } is version #{ i.command_plugins[0].output.chop }"
      end
    end
  end

  def get_data_from_s3_command_method()

    s3 = Aws::S3::Client.new(
      region: @region,
      profile: @profile
    )
    s3.list_objects(:bucket => @s3_bucket_name,
                    :prefix => "#{ @s3_bucket_pfx }/#{ @command_id }").contents.each do |object|
       matches = /(i-\w+)\/.*stdout$/.match(object.key)
       next if matches.nil?
       if !matches[1].nil?
         resp = s3.get_object(bucket: @s3_bucket_name, key: object.key)
         puts "#{matches[1]} #{resp.body.read}"
       end
    end
  end

  def parse_date(d1,d2)
    fixed = "#{d1}T#{ d2.tr('-', ':') }"
    Time.iso8601(fixed).to_i
  end

  def get_data_from_s3_association_method()
    s3 = Aws::S3::Client.new(
      region: @region,
      profile: @profile
    )

    regexp = Regexp.new(/((i-\w+)\/#{ @association_id }\/((\d{4}-\d{2}-\d{2})T(\d{2}-\d{2}-\d{2}\.\d{3}Z))).*stdout$/)

    # https://github.com/aws/aws-cli/issues/1104s
    results = Hash.new()
    latest_obj_time = Hash.new(nil)
    latest_obj_key = Hash.new(nil)
    s3.list_objects(:bucket => @s3_bucket_name,
                    :prefix => "#{ @s3_bucket_pfx }").contents.each do |object|
       matches = regexp.match(object.key)

       next if matches.nil?

       instance_id = matches[2] # Make more readable

       # Get latest results
       resp = s3.get_object(bucket: @s3_bucket_name, key: object.key)
       cur_obj_time = self.parse_date(matches[4], matches[5])

       if latest_obj_time[instance_id].nil? # First in
          latest_obj_time[instance_id] = cur_obj_time
          latest_obj_key[instance_id] = object.key
          next
       end
       if cur_obj_time > latest_obj_time[instance_id]
          latest_obj_time[instance_id] = cur_obj_time
          latest_obj_key[instance_id] = object.key
       end

       puts latest_obj_key[instance_id] if @debug

    end

    latest_obj_key.keys.each do |k|
      resp = s3.get_object(bucket: @s3_bucket_name, key: latest_obj_key[k])
      puts "#{k} #{ resp.body.read }"
    end
  end

  def get_data_from_s3_association_method_bak()
    s3 = Aws::S3::Client.new(
      region: @region,
      profile: @profile
    )

    regexp = Regexp.new(/((i-\w+)\/#{ @association_id }\/((\d{4}-\d{2}-\d{2})T(\d{2}-\d{2}-\d{2}\.\d{3}Z))).*stdout$/)

    # https://github.com/aws/aws-cli/issues/1104s
    results = Hash.new()
    latest_obj_time = nil
    latest_obj_key = nil
    s3.list_objects(:bucket => @s3_bucket_name,
                    :prefix => "#{ @s3_bucket_pfx }").contents.each do |object|
       matches = regexp.match(object.key)

       next if matches.nil?

       # Get latest results
       resp = s3.get_object(bucket: @s3_bucket_name, key: object.key)
       cur_obj_time = self.parse_date(matches[4], matches[5])

       if latest_obj_time.nil? # First in
          latest_obj_time = cur_obj_time
          next
       end
       if cur_obj_time > latest_obj_time
          latest_obj_time = cur_obj_time
          latest_obj_key = object.key
       end

       puts latest_obj_key if @debug

    end

    resp = s3.get_object(bucket: @s3_bucket_name, key: latest_obj_key)
    puts resp.body.read
  end

  def get_data_from_s3_association_by_day_method(date_pattern = (Time.now()).strftime("%Y-%m-%d"))
    s3 = Aws::S3::Client.new(
      region: @region,
      profile: @profile
    )

    regexp = Regexp.new(/((i-\w+)\/#{ @association_id }).*stdout$/)

    results = Hash.new()
    s3.list_objects(:bucket => @s3_bucket_name,
                    :prefix => "#{ date_pattern }").contents.each do |object|
       matches = regexp.match(object.key)
       next if matches.nil?
       if !matches[2].nil?
         resp = s3.get_object(bucket: @s3_bucket_name, key: object.key)
         results[matches[2]] = resp.body.read # Keep only one result
       end
    end

    puts results.inspect
  end

=begin Use Case #1
  Get association id for correct environment e.g. Dev
  Send an AWSRefresh to the assocation using send-command. This is different
  from cron invocation in that there is a command-id associated with it.
  Results output to S3 bucket with static prefix
    bucket/prefix/instance_id/association_id/timestamp
  Dependent on clearing files using bucket lifecycle as bucket size could
    be large.
=end

  def run_use_case1(delay = 60)
    puts "Running Option 1 - Refresh existing association"
    days_ago = 0
    self.get_association_id()
    self.update_association_output_s3_key_prefix(@account)
    self.send_refresh()
    sleep(delay)
    self.get_data_from_s3_association_method((Time.now() - days_ago).strftime("%Y-%m-%d"))
  end

=begin Use Case #2
    No association, just send a command with document name and targets
    Send an AWSRefresh to the assocation
    Results are accessible through api based on command id which you have to store
    somewhere so it's readable from the dashboard. Making API calls for all commands
    could be expensive as you cannot filter by date.
    No S3 requirement.
=end

  def run_use_case2(delay = 60)
    puts "Running Option 2 - Run ad-hoc command"
    self.send_command_by_tag()
    sleep(delay)
    self.get_data_from_command_invocations()
  end

=begin Use Case #3
    As use case #1, but using cron.
    No command associated run.
=end

=begin Use Case #4
    As use case #3.
    Separate job updates s3 key prefix with todays date
    Results output to S3 bucket with Date prefix
      bucket/%Y-%m-%d/instance_id/association_id/timestamp
=end
  def run_use_case4(delay = 60)
    puts "Running Option 1.1 - Refresh existing association"
    self.get_association_id()
    self.update_association_output_s3_key_prefix((Time.now()).strftime("%Y-%m-%d"))
    self.send_refresh() # No S3 output for command
    sleep(delay)
    self.get_data_from_s3_association_by_day_method()
  end

=begin Use Case #5
      As use case #4.
      No Date prefix in bucket, meaning no need to update association.
      Totally dependent on bucket lifecycle
=end
  def run_use_case5(delay = 60)
    puts "Running Option 1.1 - Refresh existing association"
    self.get_association_id()
    self.send_refresh() # No S3 output for command
    sleep(delay)
    self.get_parameter()
    self.get_data_from_s3_association_method() # Really depending on bucket lifecycle here
  end
end

environment = 'Dev'
get_versions = GetVersions.new(:account => 'redacted', :environment => environment)
get_versions.run_use_case5(30)
