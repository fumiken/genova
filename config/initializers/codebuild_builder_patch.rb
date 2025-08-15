require 'aws-sdk-codebuild'
require 'logger'
require 'dotenv/load'

module CodebuildBuilderPatch
  CANDS = %w[Genova::Builder Genova::Service::Builder Genova::Deployer::Builder]
  ENTS  = %i[build build_and_push execute create_image]

  def self.apply!
    k = CANDS.filter_map { |n| Object.const_get(n) rescue nil }.first or return
    m = ENTS.find { |x| k.method_defined?(x) || k.private_method_defined?(x) } or return

    k.class_eval do
      define_method(m) do |*a, **kw|
        log = (respond_to?(:logger) && logger) || Logger.new($stdout)
        cfg = if instance_variable_defined?(:@service_config)
                instance_variable_get(:@service_config)
              else kw[:service_config] || a.first end
        return super(*a, **kw) unless cfg && (!cfg.respond_to?(:build) || cfg.build)

        repo = (cfg.respond_to?(:image) && cfg.image) ||
               "<account>.dkr.ecr.<region>.amazonaws.com/" +
               (cfg.respond_to?(:repository_name) ? cfg.repository_name : 'app')
        tag  = (cfg.respond_to?(:image_tag) && cfg.image_tag) || Time.now.strftime('%Y%m%d%H%M%S')
        df   = (cfg.respond_to?(:dockerfile) && cfg.dockerfile) || 'Dockerfile'
        ctx  = (cfg.respond_to?(:context)    && cfg.context)    || '.'

        project_name = ENV['CODEBUILD_PROJECT_NAME'] || 'genova-build'

        bs = <<~YAML
          version: 0.2
          phases:
            pre_build:
              commands:
                - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin #{repo}
            build:
              commands:
                - docker build -f #{df} -t #{repo}:#{tag} #{ctx}
            post_build:
              commands:
                - docker push #{repo}:#{tag}
        YAML

        cb = Aws::CodeBuild::Client.new(region: ENV['AWS_REGION'] || ENV['AWS_DEFAULT_REGION'])
        id = cb.start_build(
          project_name: project_name,
          source_type_override: 'NO_SOURCE',
          buildspec_override: bs,
          environment_variables_override: [
            {name:'REPO_URI', value:repo},
            {name:'IMAGE_TAG', value:tag}
          ]
        ).build.id

        st = nil
        loop do
          sleep 5
          st = cb.batch_get_builds(ids:[id]).builds.first&.build_status
          break if %w[SUCCEEDED FAILED FAULT TIMED_OUT STOPPED].include?(st)
        end
        raise "CodeBuild failed: #{st}" unless st == 'SUCCEEDED'
        cfg.image = "#{repo}:#{tag}" if cfg.respond_to?(:image=)
        true
      end
    end
  end
end
CodebuildBuilderPatch.apply!
