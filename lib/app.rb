# -*- coding: utf-8 -*-

require 'uri'
require 'haml'
require 'sanitize'
require 'kramdown'
require 'mime-types'
require 'sinatra/base'
require 'sinatra/reloader'
require 'sinatra/config_file'

require_relative 'git'
require_relative 'error'

module RubWiki2
  class App < Sinatra::Base

    configure :development do
      register Sinatra::Reloader
      also_reload File.join(File.dirname(__FILE__), 'git.rb')
      also_reload File.join(File.dirname(__FILE__), 'error.rb')
    end

    register Sinatra::ConfigFile
    config_file File.join(File.dirname(__FILE__), '../config/config.yml')

    set :public_folder, File.join(File.dirname(__FILE__), '../public')
    set :views, File.join(File.dirname(__FILE__), '../views')
    set :haml, :escape_html => true

    helpers do
      def guess_mime(path)
        begin
          content_type MIME::Types.type_for(path)[0].to_s
        rescue
          content_type 'text/plain'
        end
      end

      def sanitize(html)
        return Sanitize.fragment(html, Sanitize::Config::RELAXED)
      end
    end

    before do
      @git = Git.new(settings.git_repo_path)
    end

    get '*/' do |path|
      path = path[1..-1] if path[0] == '/'
      obj = @git.get(path)
      entries = []
      obj.children.each do |name, obj|
        case obj.type
        when :blob
          entries << { name: File.basename(name, '.md'), type: :blob }
        when :tree
          entries << { name: name, type: :tree }
        end
      end
      article = haml(:dir, locals: { entries: entries })
      return haml(:default, locals: { article: article })
    end

    get '*' do |path|
      path = path[1..-1] if path[0] == '/'
      if @git.exist?(path + '.md')
        # file (*.md)
        obj = @git.get(path + '.md')
        article = sanitize(markdown(obj.content))
        return haml(:default, locals: { article: article })
      else
        obj = @git.get(path)
        case obj.type
        when :blob
          # file
          guess_mime(path)
          return obj.content
        when :tree
          # dir (redirect)
          redirect to(URI.encode(path) + '/')
        end
      end
    end

  end
end
