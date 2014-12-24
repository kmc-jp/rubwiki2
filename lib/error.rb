module RubWiki2
  module Error
    class InvalidPath < StandardError; end
    class EmptyCommitMessage < StandardError; end
  end
end
