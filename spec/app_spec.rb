require 'tmpdir'
require_relative '../lib/app'

RSpec.describe RubWiki2::App, type: :feature do
  let!(:app) do
    Class.new(described_class) do
      set :wikiname, 'Test Wiki'
      set :frontpage, 'Welcome'
      set :slack, false
    end
  end

  let!(:page) { Capybara::Session.new(:rack_test, app) }

  around do |example|
    Dir.mktmpdir('rubwiki2-spec') do |path|
      system('git', 'init', '--quiet', path, exception: true)
      File.write(File.join(path, 'Welcome.md'), <<~MARKDOWN)
        # Welcome to the wiki

        This page contains **bold text** and a [link](https://example.com/).
      MARKDOWN
      system('git', '-C', path, 'add', 'Welcome.md', exception: true)
      system('git', '-C', path,
             '-c', 'user.name=Test Author', '-c', 'user.email=test@example.com',
             'commit', '--quiet', '--no-gpg-sign', '-m', 'Add welcome page', exception: true)

      app.set :git_repo_path, path
      example.run
    end
  end

  it 'renders a Markdown page from the wiki repository as HTML' do
    visit '/Welcome'

    expect(page.status_code).to eq(200)
    expect(page.response_headers['content-type']).to include('text/html')
    expect(page).to have_title('Welcome | Test Wiki')

    within '#content-html' do
      expect(page).to have_css('h1.title', text: 'Welcome', exact_text: true)
      expect(page).to have_css('h1#welcome-to-the-wiki', text: 'Welcome to the wiki')
      expect(page).to have_css('p strong', text: 'bold text')
      expect(page).to have_link('link', href: 'https://example.com/')
    end
  end
end
