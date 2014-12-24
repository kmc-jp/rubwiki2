require 'rugged'

require_relative 'error'

module RubWiki2
  class Git
    def initialize(path)
      @repo = Rugged::Repository.new(path)
      @tree = Tree.get_trees(@repo)
    end

    def add(path, data)
      @tree.add(path, data)
    end

    def rm(path)
      @tree.rm(path)
    end

    def log(path = nil)
      commits = []
      @repo.walk(@repo.head.target) do |commit|
        if path == nil || commit.diff(paths: [path]).size > 0
          commits << commit
        end
      end
      return commits
    end

    def commit(kmc_id = 'anonymous', message = '')
      author = { email: "#{kmc_id}@kmc.gr.jp", name: kmc_id, time: Time.now }
      options = {
        tree: @tree.oid, author: author, committer: author, message: message,
        parents: @repo.empty? ? [] : [ @repo.head.target ].compact,
        update_ref: 'HEAD'
      }
      Rugged::Commit.create(@repo, options)
    end

    def get(path)
      @tree.get(path)
    end

    def exist?(path)
      @tree.exist?(path)
    end

    def can_create?(path)
      @tree.can_create_blob?(path)
    end

    def get_from_oid(oid)
      obj = @repo.lookup(oid)
      case obj.type
      when :blob
        return Blob.new(@repo, oid)
      when :tree
        return Tree.get_trees(@repo, oid)
      end
    end
  end

  class Blob
    def self.create(repo, data)
      oid = repo.write(data, :blob)
      return Blob.new(repo, oid)
    end

    def initialize(repo, oid)
      @repo = repo
      @oid = oid
    end

    attr_reader :oid

    def type
      return :blob
    end

    def get(path)
      if path.empty?
        return self
      else
        raise Error::InvalidPath.new
      end
    end

    def content
      @repo.lookup(@oid).text
    end
  end

  class Tree
    # children: { name1 => obj1, name2 => obj2, ... }
    def self.create(repo, children)
      oid = self.create_tree_object(repo, children)
      return Tree.new(repo, oid, children)
    end

    def self.create_tree_object(repo, children)
      builder = Rugged::Tree::Builder.new()
      children.each do |name, obj|
        case obj.type
        when :blob
          builder.insert({ type: obj.type, name: name, oid: obj.oid, filemode: 0100644 })
        when :tree
          builder.insert({ type: obj.type, name: name, oid: obj.oid, filemode: 0040000 })
        end
      end
      oid = builder.write(repo)
      return oid
    end

    def self.get_trees(repo, oid = nil)
      oid ||= repo.head.target.tree.oid
      children = {}
      repo.lookup(oid).each do |obj|
        case obj[:type]
        when :blob
          children[obj[:name]] = Blob.new(repo, obj[:oid])
        when :tree
          children[obj[:name]] = Tree.get_trees(repo, obj[:oid])
        end
      end
      return Tree.new(repo, oid, children)
    end

    def initialize(repo, oid, children)
      @repo = repo
      @oid = oid
      @children = children
    end

    attr_reader :oid, :children

    def type
      return :tree
    end

    def add(path, data)
      if path.include?('/')
        if @children.include?(path.partition('/').first)
          @children[path.partition('/').first].add(path.partition('/').last, data)
        else
          obj = Blob.create(@repo, data)
          path.split('/')[1..-1].reverse.each do |name|
            obj = Tree.create(@repo, { name => obj })
          end
          @children[path.split('/').first] = obj
        end
      else
        blob = Blob.create(@repo, data)
        @children[path] = blob
      end
      @oid = Tree.create_tree_object(@repo, @children)
    end

    def rm(path)
      if path.include?('/')
        @children[path.partition('/').first].rm(path.partition('/').last)
        if @children[path.partition('/').first].children.empty?
          @children.delete(path.partition('/').first)
        end
      else
        @children.delete(path)
      end
      @oid = Tree.create_tree_object(@repo, @children) unless @children.empty?
    end

    def get(path)
      if path.empty?
        return self
      else
        if @children.include?(path.partition('/').first)
          return @children[path.partition('/').first].get(path.partition('/').last)
        else
          raise Error::InvalidPath.new
        end
      end
    end

    def exist?(path)
      if path.include?('/')
        if @children.include?(path.partition('/').first)
          child = @children[path.partition('/').first]
          if child.type == :tree
            return child.exist?(path.partition('/').last)
          else
            return false
          end
        else
          return false
        end
      else
        return @children.include?(path)
      end
    end

    def can_create_blob?(path)
      if path.include?('/')
        if @children.include?(path.partition('/').first)
          child = @children[path.partition('/').first]
          if child.type == :tree
            return child.exist?(path.partition('/').last)
          else
            return false
          end
        else
          return true
        end
      else
        return !@children.include?(path)
      end
    end
  end
end
