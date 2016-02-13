require 'json'
# Helper methods for Testing Framework forms
module AutomatedTestsHelper
  # This is the waiting list for automated testing. Once a test is requested,
  # it is enqueued and it is waiting for execution. Resque manages this queue.
  @queue = :test_waiting_list

  def fetch_latest_tokens_for_grouping(grouping)
    token = Token.find_by(grouping: grouping)
    if token
      token.reassign_tokens_if_new_day
    end
    token
  end

  def create_test_repo(assignment)
    # Create the automated test repository
    unless File.exist?(MarkusConfigurator
                            .markus_config_automated_tests_repository)
      FileUtils.mkdir(MarkusConfigurator
                          .markus_config_automated_tests_repository)
    end

    test_dir = File.join(MarkusConfigurator
                             .markus_config_automated_tests_repository,
                         assignment.short_identifier)
    unless File.exist?(test_dir)
      FileUtils.mkdir(test_dir)
    end
  end

  # Process Testing Framework form
  # - Process new and updated test files (additional validation to be done at the model level)
  def process_test_form(assignment, params, new_script)

    updated_script_files = {}
    updated_support_files = {}

    testscripts = params[:test_scripts_attributes] || []
    testsupporters = params[:test_support_files_attributes] || []

    # Create/Update test scripts
    testscripts.each do |file_num, file|
      # If no new_script then form is empty and skip
      next if testscripts[file_num][:seq_num].empty? && new_script.nil?

      # Seq_num only exists if it is a file being edited
      if testscripts[file_num][:seq_num].empty?
        # Create new test script file
        filename = new_script.original_filename
        if TestScript.exists?(script_name: filename, assignment: assignment)
          raise I18n.t('automated_tests.duplicate_filename') + filename
        else
          # Override filename from form
          file[:script_name] = filename
          file[:seq_num] = file_num
          updated_script_files[file_num] = file.clone
        end
      else
        # Edit existing test script file
        updated_script_files[file_num] = file.clone
      end

    end

    # Create/Update test support files
    # Ignore editing files for now
    testsupporters.each do |file_num, file|
      # Empty file submission, skip
      next if testsupporters[file_num][:file_name].nil?

      updated_support_files[file_num] = {} || []
      filename = testsupporters[file_num][:file_name].original_filename

      # Create test support file if it does not exist
      if TestSupportFile.exists?(file_name: filename, assignment: assignment)
        raise I18n.t('automated_tests.duplicate_filename') + filename
      else
        updated_support_files[file_num] = file.clone
        # Override filename from form
        updated_support_files[file_num][:file_name] = filename
      end
    end

    # Update test file attributes
    assignment.test_scripts_attributes = updated_script_files
    assignment.test_support_files_attributes = updated_support_files

    # Update assignment enable_test and tokens_per_day attributes
    assignment.enable_test = params[:enable_test]
    assignment.unlimited_tokens = params[:unlimited_tokens]
    num_tokens = params[:tokens_per_day]
    if num_tokens
      assignment.tokens_per_day = num_tokens
    end

    assignment
  end

  # Verify tests can be executed
  def can_run_test?
    if @current_user.admin?
      true
    elsif @current_user.ta?
      true
    elsif @current_user.student?
      # Make sure student belongs to this group
      unless @current_user.accepted_groupings.include?(@grouping)
        return false
      end
      t = @grouping.token
      if t == nil
        raise I18n.t('automated_tests.missing_tokens')
      end
      if t.tokens > 0
        t.decrease_tokens
        true
      else
        false
      end
    end
  end


  def self.request_a_test_run(grouping_id, call_on, current_user)
    @current_user = current_user
    #@submission = Submission.find(submission_id)
    @grouping = Grouping.find(grouping_id)
    @assignment = @grouping.assignment
    @group = @grouping.group

    @repo_dir = File.join(MarkusConfigurator.markus_config_automated_tests_repository, @group.repo_name)
    export_group_repo(@group, @repo_dir)

    @list_run_scripts = scripts_to_run(@assignment, call_on)

    async_test_request(grouping_id, call_on)
  end


  # Export group repository for testing. Students' submitted files
  # are stored in the group svn repository. They must be exported
  # before copying to the test server.
  def self.export_group_repo(group, repo_dir)
    # Create the automated test repository
    unless File.exists?(MarkusConfigurator.markus_config_automated_tests_repository)
      FileUtils.mkdir(MarkusConfigurator.markus_config_automated_tests_repository)
    end

    # Delete student's assignment repository if it already exists
    delete_repo(repo_dir)

    # export
    return group.repo.export(repo_dir)
  end

  # Delete student's assignment repository if it already exists
  def self.delete_repo(repo_dir)
    if File.exists?(repo_dir)
      FileUtils.rm_rf(repo_dir)
    end
  end


  # Find the list of test scripts to run the test. Return the list of
  # test scripts in the order specified by seq_num (running order)
  def self.scripts_to_run(assignment, call_on)
    # Find all the test scripts of the current assignment
    all_scripts = TestScript.where(assignment_id: assignment.id)

    list_run_scripts = Array.new

    # If the test run is requested at collection (by Admin or TA),
    # All of the test scripts should be run.
    if call_on == 'collection'
      list_run_scripts = all_scripts
    else
      # If the test run is requested at submission or upon request,
      # verify the script is allowed to run.
      all_scripts.each do |script|
        if call_on == 'submission' && script.run_on_submission
          list_run_scripts.insert(list_run_scripts.length, script)
        elsif call_on == 'request' && script.run_on_request
          list_run_scripts.insert(list_run_scripts.length, script)
        end
      end
    end

    # sort list_run_scripts using ruby's in place sorting method
    list_run_scripts.sort_by! &:seq_num
    list_run_scripts
  end

  # Request an automated test. Ask Resque to enqueue a job.
  def self.async_test_request(grouping_id, call_on)
    if files_available? && has_permission?
      Resque.enqueue(AutomatedTestsHelper, grouping_id, call_on)
    end
  end


  # Verify that MarkUs has some files to run the test.
  # Note: this does not guarantee all required files are presented.
  # Instead, it checks if there is at least one test script and
  # source files are successfully exported.
  def self.files_available?
    test_dir = File.join(MarkusConfigurator.markus_config_automated_tests_repository, @assignment.short_identifier)
    src_dir = @repo_dir
    assign_dir = @repo_dir + '/' + @assignment.repository_folder

    if !(File.exists?(test_dir))
      # TODO: show the error to user instead of raising a runtime error
      raise I18n.t('automated_tests.test_files_unavailable')
    elsif !(File.exists?(src_dir))
      # TODO: show the error to user instead of raising a runtime error
      raise I18n.t('automated_tests.source_files_unavailable')
    end

    if !(File.exists?(assign_dir))
      # TODO: show the error to user instead of raising a runtime error
      raise I18n.t('automated_tests.source_files_unavailable')
    end

    dir_contents = Dir.entries(assign_dir)

    #if there are no files in repo (ie only the current and parent directory pointers)
    if (dir_contents.length <= 2)
      raise I18n.t('automated_tests.source_files_unavailable')
    end

    scripts = TestScript.where(assignment_id: @assignment.id)
    if scripts.empty?
      # TODO: show the error to user instead of raising a runtime error
      raise I18n.t('automated_tests.test_files_unavailable')
    end

    true
  end

  # Verify the user has the permission to run the tests - admin
  # and graders always have the permission, while student has to
  # belong to the group, and have at least one token.
  def self.has_permission?
    if @current_user.admin?
      true
    elsif @current_user.ta?
      true
    elsif @current_user.student?
      # Make sure student belongs to this group
      if not @current_user.accepted_groupings.include?(@grouping)
        # TODO: show the error to user instead of raising a runtime error
        raise I18n.t('automated_tests.not_belong_to_group')
      end
      #can skip checking tokens if we have unlimited
      if @grouping.assignment.unlimited_tokens
        return true
      end
      t = @grouping.token
      if t.nil?
        raise I18n.t('automated_tests.missing_tokens')
      end
      if t.tokens > 0
        t.decrease_tokens
        true
      else
        # TODO: show the error to user instead of raising a runtime error
        raise I18n.t('automated_tests.missing_tokens')
      end
    end
  end


  # Perform a job for automated testing. This code is run by
  # the Resque workers - it should not be called from other functions.
  def self.perform(grouping_id, call_on)
    #@submission = Submission.find(submission_id)
    @grouping = Grouping.find(grouping_id)
    @assignment = @grouping.assignment
    @group = @grouping.group
    @repo_dir = File.join(MarkusConfigurator.markus_config_automated_tests_repository, @group.repo_name)

    stderr, result, status = launch_test(@assignment, @repo_dir, call_on)

    if !status
      #for debugging any errors in launch_test
      assignment = @assignment
      repo_dir = @repo_dir
      m_logger = MarkusLogger.instance


      src_dir = File.join(repo_dir, assignment.repository_folder)

      # Get test_dir
      test_dir = File.join(MarkusConfigurator.markus_config_automated_tests_repository, assignment.repository_folder)

      # Get the name of the test server
      server = 'localhost'

      # Get the directory and name of the test runner script
      test_runner = MarkusConfigurator.markus_ate_test_runner_script_name

      # Get the test run directory of the files
      run_dir = MarkusConfigurator.markus_ate_test_run_directory


      m_logger.log("error with launching test, error: #{stderr} and status: #{status}\n src_dir: #{src_dir}\ntest_dir: #{test_dir}\nserver: #{server}\ntest_runner: #{test_runner}\nrun_dir: #{run_dir}",MarkusLogger::ERROR)

      # TODO: handle this error better
      raise 'error'
    else
      process_result(result)
    end

  end

  # Launch the test on the test server by scp files to the server
  # and run the script.
  # This function returns three values:
  # stderr
  # stdout
  # boolean indicating whether execution suceeeded
  def self.launch_test(assignment, repo_path, call_on)
    submission_path = File.join(repo_path, assignment.repository_folder)
    assignment_tests_path = File.join(MarkusConfigurator.markus_config_automated_tests_repository, assignment.repository_folder)

    test_harness_path = MarkusConfigurator.markus_ate_test_runner_script_name

    # Where to run the tests
    test_box_path = MarkusConfigurator.markus_ate_test_run_directory

    # Create clean folder to execute tests
    stdout, stderr, status = Open3.capture3("rm -rf #{test_box_path} && "\
      "mkdir #{test_box_path}")
    unless status.success?
      return [stderr, stdout, status]
    end

    # Securely copy student's submission, test files and test harness script to test_box_path
    stdout, stderr, status = Open3.capture3("cp -r '#{submission_path}'/* "\
      "#{test_box_path}")
    unless status.success?
      return [stderr, stdout, status]
    end

    stdout, stderr, status = Open3.capture3("cp -r '#{assignment_tests_path}'/* "\
      "#{test_box_path}")
    unless status.success?
      return [stderr, stdout, status]
    end

    stdout, stderr, status = Open3.capture3("cp -r #{test_harness_path} "\
      "#{test_box_path}")
    unless status.success?
      return [stderr, stdout, status]
    end

    # Find the test scripts for this test run, and parse the argument list
    list_run_scripts = scripts_to_run(assignment, call_on)
    arg_list = ''
    list_run_scripts.each do |script|
      arg_list = arg_list + "#{script.script_name.gsub(/\s/, "\\ ")} #{script.halts_testing} "
    end

    # Run script
    test_harness_name = File.basename(test_harness_path)
    stdout, stderr, status = Open3.capture3("cd #{test_box_path}; "\
      "ruby #{test_harness_name} #{arg_list}")

    if !(status.success?)
      return [stderr, stdout, false]
    else
      test_results_path = "#{AUTOMATED_TESTS_REPOSITORY}/test_runs/test_run_#{Time.now.to_i}"
      FileUtils.mkdir_p(test_results_path)
      File.write("#{test_results_path}/output.txt", stdout)
      File.write("#{test_results_path}/error.txt", stderr)
      return [stdout, stdout, true]
    end
  end

  def self.process_result(raw_result)
    result = Hash.from_xml(raw_result)
    repo = @grouping.group.repo
    revision = repo.get_latest_revision
    revision_number = revision.revision_number
    raw_test_scripts = result['testrun']['test_script']

    # Hash.from_xml will yield a hash if only one test script
    # and an array otherwise
    if raw_test_scripts.nil?
      return
    elsif raw_test_scripts.is_a?(Array)
      test_scripts = raw_test_scripts
    else
      test_scripts = [raw_test_scripts]
    end

    # For now, we just use the first test script for the association
    raw_test_script = test_scripts.first
    script_name = raw_test_script['script_name']
    test_script = TestScript.find_by(assignment_id: @assignment.id,
                                     script_name: script_name)

    completion_status = 'pass'
    marks_earned = 0
    test_scripts.each do |script|
      tests = script['test']
      tests.each do |test|
        marks_earned += test['marks_earned'].to_i
        # if any of the tests fail, we consider the completion status to be fail
        completion_status = 'fail' if test['status'] != 'pass'
      end
    end

    # TODO: HACK. Do we always need a submission id?
    submission_id = Submission.last.id
    TestResult.create(grouping_id: @grouping.id,
                      test_script_id: test_script.id,
                      name: script_name,
                      repo_revision: revision_number,
                      input_description: '',
                      actual_output: result.to_json,
                      expected_output: '',
                      submission_id: submission_id,
                      marks_earned: marks_earned,
                      completion_status: completion_status)
  end
end
