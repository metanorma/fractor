# Fractor Documentation

This directory contains the documentation for Fractor, built with Jekyll and the just-the-docs theme.

## Building Locally

### Prerequisites

- Ruby 3.0 or later
- Bundler (`gem install bundler`)

### Setup

Install dependencies:

```bash
cd docs
bundle install
```

### Development Server

Run the Jekyll development server:

```bash
cd docs
bundle install
bundle exec jekyll serve --livereload --baseurl /fractor
```

Then visit http://localhost:4000/fractor in your browser.

The `--livereload` option enables automatic page refresh when files change.
The `--baseurl /fractor` option matches the GitHub Pages deployment URL.

### Building for Production

Build the static site:

```bash
bundle exec jekyll build
```

The generated site will be in `_site/`.

## Link Checking

This documentation uses [lychee](https://github.com/lycheeverse/lychee) for link validation.

### Install lychee

```bash
# macOS
brew install lychee

# Cargo (all platforms)
cargo install lychee

# Or download binary from releases
```

### Run link checker

Check all links in the documentation:

```bash
lychee docs/
```

Or check the built site:

```bash
lychee _site/
```

Configuration is in `lychee.toml` and `.lycheeignore`.

## Documentation Structure

The documentation follows an onion structure from beginner to advanced:

```
docs/
├── index.md                    # Landing page
├── _tutorials/                 # Beginner guides
│   ├── index.md
│   ├── installation.adoc
│   ├── first-application.adoc
│   └── getting-started.adoc
├── _guides/                    # Intermediate topics
│   ├── index.md
│   ├── core-concepts.adoc
│   ├── pipeline-mode.adoc
│   ├── continuous-mode.adoc
│   ├── workflows.adoc
│   ├── error-reporting.adoc
│   └── signal-handling.adoc
└── _reference/                 # Advanced/API reference
    ├── index.md
    ├── api.adoc
    ├── examples.adoc
    └── patterns.adoc
```

## Writing Documentation

### Front Matter

All documentation files must include YAML front matter:

```yaml
---
layout: default
title: Page Title
parent: Parent Section
nav_order: 1
---
```

### AsciiDoc Files

AsciiDoc files should:
- Start with level 2 headings (`==`) not level 1 (`=`)
- Use proper heading hierarchy
- Include code syntax highlighting with `[source,language]`

### Markdown Files

Markdown files should:
- Use `#` for headings (Jekyll will handle levels)
- Use fenced code blocks with language tags
- Follow just-the-docs conventions

### Navigation

Navigation is automatically generated from:
- Front matter `nav_order` values
- Collection configuration in `_config.yml`
- Directory structure

## Contributing

When adding new documentation:

1. Choose the appropriate section (tutorials/guides/reference)
2. Add proper front matter
3. Use consistent heading levels
4. Add code examples where relevant
5. Test locally with `bundle exec jekyll serve`
6. Run link checker: `lychee docs/`
7. Submit a pull request

## Deployment

Documentation is automatically deployed to GitHub Pages when changes are merged to the main branch.

Site URL: https://metanorma.github.io/fractor