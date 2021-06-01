# Helper for replacing unwanted characters in filenames.
module FileHelper
  # Only allow alphanumeric characters, '.', '-', and '_' as
  # character set for submission files.
  FILENAME_SANITIZATION_REGEXP = Regexp.new('[^0-9a-zA-Z\.\-_]').freeze
  # Character to be used as a replacement for all characters
  # matching the regular expression above
  SUBSTITUTION_CHAR = '_'.freeze

  def sanitize_file_name(file_name)
    # If file_name is blank, return the empty string
    return '' if file_name.nil?
    File.basename(file_name).gsub(
      FILENAME_SANITIZATION_REGEXP,
      SUBSTITUTION_CHAR
    )
  end
end
