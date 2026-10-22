# Contributing to VerityTick

## Getting Started

1. Fork the repository
2. Clone your fork
3. Copy `.env.example` to `.env` and configure PostgreSQL credentials
4. Install dependencies: `pip install -e ".[dev]"`
5. Create the database: `python tools/setup_db.py`
6. Run tests: `pytest tests/ -v`

## Development Workflow

1. Create a feature branch: `git checkout -b feat/your-feature`
2. Make changes and add tests
3. Run the test suite before committing
4. Write clear commit messages using conventional commits
5. Push and open a pull request

## Commit Messages

Use conventional commit prefixes:

- `feat(module):` — New functionality
- `fix(module):` — Bug fixes
- `test(module):` — Test additions or fixes
- `docs(topic):` — Documentation changes
- `perf(module):` — Performance improvements
- `chore(scope):` — Build/tooling changes

## SQL Style

- Use `UPPERCASE` for SQL keywords
- Use `snake_case` for identifiers
- Include comments for non-obvious logic
- Use `NUMERIC` for financial amounts, never `FLOAT`

## Security

- **Never** commit credentials, passwords, or tokens
- **Never** commit `.env` files
- Test security changes under restricted roles
