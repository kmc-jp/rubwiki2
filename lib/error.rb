module RubWiki2
  module Error
    class InvalidPath < StandardError
      def initialize(message)
        super(message)
      end
    end

    class FileNotFound < StandardError
      def initialize(message)
        super(message)
      end
    end
    class EmptyCommitMessage < StandardError; end
  end
end
