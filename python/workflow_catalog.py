"""Curated browser workflow catalog — stable IDs, prompt examples, replay actions."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any
from urllib.parse import quote_plus


@dataclass
class WorkflowSpec:
    id: str
    name: str
    category: str
    prompts: list[str]
    actions: list[dict[str, Any]]
    params: dict[str, str] = field(default_factory=dict)
    tags: list[str] = field(default_factory=list)


def _google(q: str) -> str:
    return f"https://www.google.com/search?q={quote_plus(q)}"


def _google_tab(q: str, tbm: str) -> str:
    return f"https://www.google.com/search?q={quote_plus(q)}&tbm={tbm}"


def _youtube(q: str) -> str:
    return f"https://www.youtube.com/results?search_query={quote_plus(q)}"


def _github(q: str, kind: str = "repositories") -> str:
    return f"https://github.com/search?q={quote_plus(q)}&type={kind}"


def _amazon(q: str) -> str:
    return f"https://www.amazon.com/s?k={quote_plus(q)}"


def _wiki(q: str) -> str:
    return f"https://en.wikipedia.org/wiki/Special:Search?search={quote_plus(q)}"


def _wiki_article(title: str) -> str:
    slug = title.replace(" ", "_")
    return f"https://en.wikipedia.org/wiki/{quote_plus(slug)}"


def _hn(q: str) -> str:
    return f"https://hn.algolia.com/?q={quote_plus(q)}"


def _reddit(q: str) -> str:
    return f"https://www.reddit.com/search/?q={quote_plus(q)}"


def _stackoverflow(q: str) -> str:
    return f"https://stackoverflow.com/search?q={quote_plus(q)}"


def _npm(q: str) -> str:
    return f"https://www.npmjs.com/search?q={quote_plus(q)}"


def _pypi(q: str) -> str:
    return f"https://pypi.org/search/?q={quote_plus(q)}"


def _mdn(q: str) -> str:
    return f"https://developer.mozilla.org/en-US/search?q={quote_plus(q)}"


def _news(q: str) -> str:
    return f"https://news.google.com/search?q={quote_plus(q)}"


def _maps_search(q: str) -> str:
    return f"https://www.google.com/maps/search/{quote_plus(q)}"


def _maps_directions(origin: str, dest: str) -> str:
    return (
        "https://www.google.com/maps/dir/?api=1"
        f"&origin={quote_plus(origin)}&destination={quote_plus(dest)}"
    )


def _linkedin_jobs(keywords: str, location: str = "") -> str:
    base = f"https://www.linkedin.com/jobs/search/?keywords={quote_plus(keywords)}"
    if location:
        base += f"&location={quote_plus(location)}"
    return base


def _yelp(q: str, where: str = "San Francisco, CA") -> str:
    return f"https://www.yelp.com/search?find_desc={quote_plus(q)}&find_loc={quote_plus(where)}"


def _booking(city: str) -> str:
    return f"https://www.booking.com/searchresults.html?ss={quote_plus(city)}"


def _weather(city: str) -> str:
    return _google(f"weather {city}")


def _arxiv(q: str) -> str:
    return f"https://arxiv.org/search/?query={quote_plus(q)}&searchtype=all"


def _scholar(q: str) -> str:
    return f"https://scholar.google.com/scholar?q={quote_plus(q)}"


def _imdb(title: str) -> str:
    return f"https://www.imdb.com/find/?q={quote_plus(title)}"


def _spotify(q: str) -> str:
    return f"https://open.spotify.com/search/{quote_plus(q)}"


def _crates(q: str) -> str:
    return f"https://crates.io/search?q={quote_plus(q)}"


def _producthunt(q: str) -> str:
    return f"https://www.producthunt.com/search?q={quote_plus(q)}"


def _nav(url: str) -> dict[str, Any]:
    return {"type": "navigate", "url": url}


def _search(query: str) -> dict[str, Any]:
    return {"type": "search", "value": query}


def _google_ui_search(query: str) -> list[dict[str, Any]]:
    """Type into Google homepage — more realistic multi-step flow."""
    return [
        _nav("https://www.google.com"),
        {"type": "click", "selector": "textarea[name='q']", "text": "Search", "partial": True},
        {"type": "type", "value": query, "selector": "textarea[name='q']"},
        {"type": "press", "value": "Enter"},
    ]


def _flight_actions(origin: str, dest: str, depart_date: str) -> list[dict[str, Any]]:
    day = str(int(depart_date.split("-")[2]))
    url = "https://www.googlePrice.com/travel/flights"
    url = "https://www.google.com/travel/flights"
    return [
        _nav(url),
        {"type": "wait", "text": "Where from", "timeout": 25_000},
        {"type": "click", "text": "One way", "partial": True},
        {"type": "click", "text": "Where from", "partial": True},
        {"type": "type", "value": origin, "text": "Where from"},
        {"type": "wait", "value": "1500"},
        {"type": "press", "value": "ArrowDown"},
        {"type": "press", "value": "Enter"},
        {"type": "click", "text": "Where to", "partial": True},
        {"type": "type", "value": dest, "text": "Where to"},
        {"type": "wait", "value": "1500"},
        {"type": "press", "value": "ArrowDown"},
        {"type": "press", "value": "Enter"},
        {"type": "click", "text": "Departure", "partial": True},
        {"type": "wait", "value": "1000"},
        {"type": "click", "text": day, "partial": True},
        {"type": "click", "text": "Done", "partial": True},
        {"type": "click", "text": "Search", "partial": True},
    ]


def _duckduckgo_ui(query: str) -> list[dict[str, Any]]:
    return [
        _nav("https://duckduckgo.com"),
        {"type": "click", "selector": "#searchbox_input", "text": "Search", "partial": True},
        {"type": "type", "value": query, "selector": "#searchbox_input"},
        {"type": "press", "value": "Enter"},
    ]


def _github_ui_search(query: str) -> list[dict[str, Any]]:
    return [
        _nav("https://github.com"),
        {"type": "click", "selector": "input[name='query-builder-test']", "text": "Search", "partial": True},
        {"type": "type", "value": query, "selector": "input[name='query-builder-test']"},
        {"type": "press", "value": "Enter"},
    ]


# ---------------------------------------------------------------------------
# Catalog
# ---------------------------------------------------------------------------

CATALOG: list[WorkflowSpec] = [
    # --- Google search (direct URL) ---
    WorkflowSpec(
        id="search_google_ai_agents",
        name="Search Google: AI agents",
        category="search",
        prompts=["search google for ai agents", "google ai agents", "look up ai agents"],
        actions=[_nav(_google("AI agents browser automation"))],
        tags=["google", "search"],
    ),
    WorkflowSpec(
        id="search_google_swift",
        name="Search Google: Swift programming",
        category="search",
        prompts=["search swift programming", "google swiftui tutorial", "swift macos development"],
        actions=[_nav(_google("Swift programming macOS SwiftUI"))],
        tags=["google", "search", "dev"],
    ),
    WorkflowSpec(
        id="search_google_react",
        name="Search Google: React hooks",
        category="search",
        prompts=["search react hooks", "google react useEffect guide", "react hooks tutorial"],
        actions=[_nav(_google("React hooks tutorial useEffect"))],
        tags=["google", "search", "dev"],
    ),
    WorkflowSpec(
        id="search_google_ml",
        name="Search Google: machine learning",
        category="search",
        prompts=["search machine learning basics", "google ml tutorial", "learn machine learning"],
        actions=[_nav(_google("machine learning tutorial for beginners"))],
        tags=["google", "search"],
    ),
    WorkflowSpec(
        id="search_google_recipes",
        name="Search Google: pasta recipes",
        category="search",
        prompts=["search pasta recipes", "how to cook pasta", "easy pasta recipe"],
        actions=[_nav(_google("easy pasta recipe"))],
        tags=["google", "search", "food"],
    ),
    WorkflowSpec(
        id="search_google_yc",
        name="Search Google: YC startups",
        category="search",
        prompts=["search y combinator startups", "yc batch companies", "ycombinator recent startups"],
        actions=[_nav(_google("Y Combinator startups 2026"))],
        tags=["google", "search", "startup"],
    ),
    WorkflowSpec(
        id="search_google_images_cats",
        name="Google Images: cute cats",
        category="search",
        prompts=["google images cute cats", "search cat pictures", "image search cats"],
        actions=[_nav(_google_tab("cute cats", "isch"))],
        tags=["google", "images"],
    ),
    WorkflowSpec(
        id="search_google_news_ai",
        name="Google News: AI regulation",
        category="search",
        prompts=["google news ai regulation", "latest ai news", "ai policy news"],
        actions=[_nav(_news("AI regulation"))],
        tags=["google", "news"],
    ),
    WorkflowSpec(
        id="search_google_shopping_keyboard",
        name="Google Shopping: mechanical keyboard",
        category="search",
        prompts=["google shopping mechanical keyboard", "shop for mechanical keyboard", "buy keyboard online"],
        actions=[_nav(_google_tab("mechanical keyboard", "shop"))],
        tags=["google", "shopping"],
    ),
    WorkflowSpec(
        id="search_google_ui_python",
        name="Google UI search: Python asyncio",
        category="search",
        prompts=["type into google python asyncio", "google search python asyncio tutorial"],
        actions=_google_ui_search("python asyncio tutorial"),
        tags=["google", "search", "interactive"],
    ),

    # --- YouTube ---
    WorkflowSpec(
        id="search_youtube_swift",
        name="YouTube: Swift tutorials",
        category="video",
        prompts=["search youtube swift tutorials", "youtube swiftui", "find swift videos"],
        actions=[_nav(_youtube("SwiftUI macOS tutorial"))],
        tags=["youtube", "dev"],
    ),
    WorkflowSpec(
        id="search_youtube_cooking",
        name="YouTube: cooking videos",
        category="video",
        prompts=["youtube cooking videos", "search youtube recipes", "cooking tutorial youtube"],
        actions=[_nav(_youtube("easy dinner recipes"))],
        tags=["youtube", "food"],
    ),
    WorkflowSpec(
        id="search_youtube_music_lofi",
        name="YouTube: lofi music",
        category="video",
        prompts=["youtube lofi music", "play lofi beats youtube", "lofi study music"],
        actions=[_nav(_youtube("lofi hip hop study beats"))],
        tags=["youtube", "music"],
    ),
    WorkflowSpec(
        id="search_youtube_documentary",
        name="YouTube: space documentary",
        category="video",
        prompts=["youtube space documentary", "watch space documentary", "nasa documentary youtube"],
        actions=[_nav(_youtube("space documentary full"))],
        tags=["youtube"],
    ),
    WorkflowSpec(
        id="search_youtube_agent",
        name="YouTube: browser agent demos",
        category="video",
        prompts=["youtube browser agent demo", "computer use agent demo", "ai browser automation video"],
        actions=[_nav(_youtube("browser agent automation demo"))],
        tags=["youtube", "ai"],
    ),

    # --- GitHub ---
    WorkflowSpec(
        id="search_github_swift_browser",
        name="GitHub: Swift browser repos",
        category="dev",
        prompts=["search github swift browser", "find swift webview browser repo", "github macos browser"],
        actions=[_nav(_github("swift wkwebview browser macos"))],
        tags=["github", "dev"],
    ),
    WorkflowSpec(
        id="search_github_agent",
        name="GitHub: browser agent repos",
        category="dev",
        prompts=["github browser agent", "search github computer use agent", "playwright agent repo"],
        actions=[_nav(_github("browser agent playwright"))],
        tags=["github", "ai"],
    ),
    WorkflowSpec(
        id="search_github_react_ui",
        name="GitHub: React component libraries",
        category="dev",
        prompts=["github react component library", "search shadcn alternatives", "react ui kit github"],
        actions=[_nav(_github("react component library ui"))],
        tags=["github", "dev"],
    ),
    WorkflowSpec(
        id="search_github_python_mcp",
        name="GitHub: MCP server Python",
        category="dev",
        prompts=["github mcp server python", "model context protocol python", "mcp tools github"],
        actions=[_nav(_github("mcp server python"))],
        tags=["github", "ai"],
    ),
    WorkflowSpec(
        id="search_github_ui_rust",
        name="GitHub UI search: Rust web framework",
        category="dev",
        prompts=["type github search rust web framework", "github search rust axum"],
        actions=_github_ui_search("rust web framework axum"),
        tags=["github", "interactive"],
    ),

    # --- Amazon ---
    WorkflowSpec(
        id="search_amazon_laptop_stand",
        name="Amazon: laptop stand",
        category="shopping",
        prompts=["amazon laptop stand", "shop laptop stand", "buy laptop stand amazon"],
        actions=[_nav(_amazon("laptop stand adjustable"))],
        tags=["amazon", "shopping"],
    ),
    WorkflowSpec(
        id="search_amazon_keyboard",
        name="Amazon: mechanical keyboard",
        category="shopping",
        prompts=["amazon mechanical keyboard", "shop mechanical keyboard", "buy keyboard amazon"],
        actions=[_nav(_amazon("mechanical keyboard wireless"))],
        tags=["amazon", "shopping"],
    ),
    WorkflowSpec(
        id="search_amazon_book_ml",
        name="Amazon: ML books",
        category="shopping",
        prompts=["amazon machine learning book", "buy ml textbook", "deep learning book amazon"],
        actions=[_nav(_amazon("hands on machine learning book"))],
        tags=["amazon", "books"],
    ),
    WorkflowSpec(
        id="search_amazon_monitor",
        name="Amazon: ultrawide monitor",
        category="shopping",
        prompts=["amazon ultrawide monitor", "shop 34 inch monitor", "buy ultrawide display"],
        actions=[_nav(_amazon("ultrawide monitor 34 inch"))],
        tags=["amazon", "shopping"],
    ),

    # --- Wikipedia ---
    WorkflowSpec(
        id="wiki_swift_programming",
        name="Wikipedia: Swift programming language",
        category="reference",
        prompts=["wikipedia swift programming", "read about swift language", "swift wikipedia article"],
        actions=[_nav(_wiki_article("Swift (programming language)"))],
        tags=["wikipedia"],
    ),
    WorkflowSpec(
        id="wiki_reinforcement_learning",
        name="Wikipedia: reinforcement learning",
        category="reference",
        prompts=["wikipedia reinforcement learning", "what is reinforcement learning", "rl wikipedia"],
        actions=[_nav(_wiki_article("Reinforcement learning"))],
        tags=["wikipedia", "ai"],
    ),
    WorkflowSpec(
        id="wiki_y_combinator",
        name="Wikipedia: Y Combinator",
        category="reference",
        prompts=["wikipedia y combinator", "read about yc", "y combinator history"],
        actions=[_nav(_wiki_article("Y Combinator"))],
        tags=["wikipedia", "startup"],
    ),
    WorkflowSpec(
        id="wiki_search_quantum",
        name="Wikipedia search: quantum computing",
        category="reference",
        prompts=["search wikipedia quantum computing", "wikipedia quantum computer"],
        actions=[_nav(_wiki("quantum computing"))],
        tags=["wikipedia"],
    ),

    # --- Developer tools ---
    WorkflowSpec(
        id="search_stackoverflow_swiftui",
        name="Stack Overflow: SwiftUI question",
        category="dev",
        prompts=["stackoverflow swiftui list", "search stack overflow swiftui", "swiftui question stackoverflow"],
        actions=[_nav(_stackoverflow("SwiftUI List performance"))],
        tags=["stackoverflow", "dev"],
    ),
    WorkflowSpec(
        id="search_npm_react_query",
        name="npm: TanStack Query",
        category="dev",
        prompts=["npm tanstack query", "search npm react query", "find tanstack query package"],
        actions=[_nav(_npm("@tanstack/react-query"))],
        tags=["npm", "dev"],
    ),
    WorkflowSpec(
        id="search_pypi_playwright",
        name="PyPI: Playwright",
        category="dev",
        prompts=["pypi playwright", "search pypi playwright python", "python playwright package"],
        actions=[_nav(_pypi("playwright"))],
        tags=["pypi", "dev"],
    ),
    WorkflowSpec(
        id="search_mdn_fetch",
        name="MDN: fetch API",
        category="dev",
        prompts=["mdn fetch api", "search mdn fetch", "javascript fetch documentation"],
        actions=[_nav(_mdn("fetch API"))],
        tags=["mdn", "dev"],
    ),
    WorkflowSpec(
        id="search_crates_tokio",
        name="crates.io: tokio",
        category="dev",
        prompts=["crates.io tokio", "rust tokio crate", "search tokio async runtime"],
        actions=[_nav(_crates("tokio"))],
        tags=["rust", "dev"],
    ),

    # --- News & forums ---
    WorkflowSpec(
        id="search_hn_ai",
        name="Hacker News: AI agents",
        category="news",
        prompts=["hacker news ai agents", "search hn ai", "hn browser automation"],
        actions=[_nav(_hn("AI agents"))],
        tags=["hackernews"],
    ),
    WorkflowSpec(
        id="search_hn_startup",
        name="Hacker News: startup advice",
        category="news",
        prompts=["hacker news startup advice", "hn founder advice", "search hn startups"],
        actions=[_nav(_hn("startup advice"))],
        tags=["hackernews", "startup"],
    ),
    WorkflowSpec(
        id="search_reddit_macos",
        name="Reddit: macOS apps",
        category="news",
        prompts=["reddit macos apps", "search reddit mac apps", "best macos apps reddit"],
        actions=[_nav(_reddit("best macOS apps"))],
        tags=["reddit"],
    ),
    WorkflowSpec(
        id="search_reddit_programming",
        name="Reddit: programming",
        category="news",
        prompts=["reddit programming", "search r programming", "programming discussion reddit"],
        actions=[_nav(_reddit("programming"))],
        tags=["reddit", "dev"],
    ),
    WorkflowSpec(
        id="search_producthunt_ai",
        name="Product Hunt: AI tools",
        category="news",
        prompts=["product hunt ai tools", "search product hunt ai", "new ai products"],
        actions=[_nav(_producthunt("AI tools"))],
        tags=["producthunt", "startup"],
    ),

    # --- Research ---
    WorkflowSpec(
        id="search_arxiv_llm",
        name="arXiv: LLM agents",
        category="research",
        prompts=["arxiv llm agents", "search arxiv language model agents", "research llm agents paper"],
        actions=[_nav(_arxiv("LLM agents"))],
        tags=["arxiv", "research"],
    ),
    WorkflowSpec(
        id="search_scholar_rl",
        name="Google Scholar: reinforcement learning",
        category="research",
        prompts=["google scholar reinforcement learning", "scholar rl papers", "research rl policy gradient"],
        actions=[_nav(_scholar("reinforcement learning policy gradient"))],
        tags=["scholar", "research"],
    ),

    # --- Maps & travel ---
    WorkflowSpec(
        id="maps_coffee_sf",
        name="Google Maps: coffee shops SF",
        category="local",
        prompts=["google maps coffee san francisco", "find coffee shops sf", "maps coffee near me sf"],
        actions=[_nav(_maps_search("coffee shops San Francisco"))],
        tags=["maps", "local"],
    ),
    WorkflowSpec(
        id="maps_directions_bos_cambridge",
        name="Google Maps: BOS to Cambridge",
        category="local",
        prompts=["directions boston to cambridge", "maps boston cambridge", "drive boston to cambridge"],
        actions=[_nav(_maps_directions("Boston Logan Airport", "Cambridge MA"))],
        tags=["maps", "directions"],
    ),
    WorkflowSpec(
        id="maps_directions_home_work",
        name="Google Maps: home to work",
        category="local",
        prompts=["directions home to work", "commute directions", "maps route to office"],
        actions=[_nav(_maps_directions("{origin}", "{dest}"))],
        params={"origin": "San Francisco", "dest": "Palo Alto"},
        tags=["maps", "directions"],
    ),
    WorkflowSpec(
        id="booking_hotels_paris",
        name="Booking.com: hotels in Paris",
        category="travel",
        prompts=["book hotel paris", "booking.com paris hotels", "find hotels paris"],
        actions=[_nav(_booking("Paris, France"))],
        tags=["travel", "hotels"],
    ),
    WorkflowSpec(
        id="booking_hotels_tokyo",
        name="Booking.com: hotels in Tokyo",
        category="travel",
        prompts=["book hotel tokyo", "booking.com tokyo", "hotels tokyo japan"],
        actions=[_nav(_booking("Tokyo, Japan"))],
        tags=["travel", "hotels"],
    ),

    # --- Flights (interactive) ---
    WorkflowSpec(
        id="flight_bos_lax",
        name="Book flight BOS to LAX",
        category="travel",
        prompts=["book flight boston to los angeles", "flight bos to lax", "flights boston la july"],
        actions=_flight_actions("BOS", "LAX", "2026-07-15"),
        params={"origin": "BOS", "destination": "LAX", "departDate": "2026-07-15"},
        tags=["flights", "google", "interactive"],
    ),
    WorkflowSpec(
        id="flight_sfo_jfk",
        name="Book flight SFO to JFK",
        category="travel",
        prompts=["book flight san francisco to new york", "flight sfo to jfk", "sf to nyc flight"],
        actions=_flight_actions("SFO", "JFK", "2026-07-20"),
        params={"origin": "SFO", "destination": "JFK", "departDate": "2026-07-20"},
        tags=["flights", "google", "interactive"],
    ),
    WorkflowSpec(
        id="flight_sea_mia",
        name="Book flight SEA to MIA",
        category="travel",
        prompts=["book flight seattle to miami", "flight sea to mia", "seattle miami flights"],
        actions=_flight_actions("SEA", "MIA", "2026-08-01"),
        params={"origin": "SEA", "destination": "MIA", "departDate": "2026-08-01"},
        tags=["flights", "google", "interactive"],
    ),
    WorkflowSpec(
        id="flight_ord_den",
        name="Book flight ORD to DEN",
        category="travel",
        prompts=["book flight chicago to denver", "flight ord to den", "chicago denver flights"],
        actions=_flight_actions("ORD", "DEN", "2026-07-12"),
        params={"origin": "ORD", "destination": "DEN", "departDate": "2026-07-12"},
        tags=["flights", "google", "interactive"],
    ),
    WorkflowSpec(
        id="flight_atl_sea",
        name="Book flight ATL to SEA",
        category="travel",
        prompts=["book flight atlanta to seattle", "flight atl to sea", "atlanta seattle flights"],
        actions=_flight_actions("ATL", "SEA", "2026-07-18"),
        params={"origin": "ATL", "destination": "SEA", "departDate": "2026-07-18"},
        tags=["flights", "google", "interactive"],
    ),

    # --- Jobs ---
    WorkflowSpec(
        id="jobs_swift_ios_sf",
        name="LinkedIn jobs: iOS Swift SF",
        category="jobs",
        prompts=["linkedin ios swift jobs san francisco", "find swift developer jobs sf", "ios engineer jobs"],
        actions=[_nav(_linkedin_jobs("iOS Swift developer", "San Francisco, CA"))],
        tags=["linkedin", "jobs"],
    ),
    WorkflowSpec(
        id="jobs_ml_engineer_remote",
        name="LinkedIn jobs: ML engineer remote",
        category="jobs",
        prompts=["linkedin ml engineer remote", "machine learning jobs remote", "ai engineer jobs"],
        actions=[_nav(_linkedin_jobs("machine learning engineer remote"))],
        tags=["linkedin", "jobs"],
    ),

    # --- Local & lifestyle ---
    WorkflowSpec(
        id="yelp_sushi_sf",
        name="Yelp: sushi in San Francisco",
        category="local",
        prompts=["yelp sushi san francisco", "find sushi sf", "best sushi yelp sf"],
        actions=[_nav(_yelp("sushi", "San Francisco, CA"))],
        tags=["yelp", "food"],
    ),
    WorkflowSpec(
        id="yelp_coffee_nyc",
        name="Yelp: coffee in NYC",
        category="local",
        prompts=["yelp coffee nyc", "best coffee new york yelp", "coffee shops manhattan"],
        actions=[_nav(_yelp("coffee", "New York, NY"))],
        tags=["yelp", "food"],
    ),
    WorkflowSpec(
        id="weather_sf",
        name="Weather: San Francisco",
        category="local",
        prompts=["weather san francisco", "sf weather today", "what's the weather in san francisco"],
        actions=[_nav(_weather("San Francisco"))],
        tags=["weather"],
    ),
    WorkflowSpec(
        id="weather_nyc",
        name="Weather: New York",
        category="local",
        prompts=["weather new york", "nyc weather today", "weather in new york city"],
        actions=[_nav(_weather("New York City"))],
        tags=["weather"],
    ),

    # --- Entertainment ---
    WorkflowSpec(
        id="imdb_inception",
        name="IMDb: search Inception",
        category="entertainment",
        prompts=["imdb inception", "search imdb inception", "inception movie imdb"],
        actions=[_nav(_imdb("Inception"))],
        tags=["imdb", "movies"],
    ),
    WorkflowSpec(
        id="spotify_jazz",
        name="Spotify: jazz playlist",
        category="entertainment",
        prompts=["spotify jazz playlist", "search spotify jazz", "find jazz on spotify"],
        actions=[_nav(_spotify("jazz playlist"))],
        tags=["spotify", "music"],
    ),

    # --- DuckDuckGo (privacy search) ---
    WorkflowSpec(
        id="search_ddg_privacy",
        name="DuckDuckGo: online privacy",
        category="search",
        prompts=["duckduckgo online privacy", "search ddg privacy tools", "private search privacy tips"],
        actions=_duckduckgo_ui("online privacy best practices"),
        tags=["duckduckgo", "search", "interactive"],
    ),
    WorkflowSpec(
        id="search_ddg_rust",
        name="DuckDuckGo: Rust async",
        category="search",
        prompts=["duckduckgo rust async", "ddg search rust tokio", "private search rust async"],
        actions=_duckduckgo_ui("rust async tokio tutorial"),
        tags=["duckduckgo", "search", "interactive"],
    ),

    # --- Misc useful ---
    WorkflowSpec(
        id="search_google_flights_page",
        name="Open Google Flights",
        category="travel",
        prompts=["open google flights", "go to google flights", "google flights homepage"],
        actions=[_nav("https://www.google.com/travel/flights")],
        tags=["flights", "navigate"],
    ),
    WorkflowSpec(
        id="search_google_maps_page",
        name="Open Google Maps",
        category="local",
        prompts=["open google maps", "go to google maps", "google maps homepage"],
        actions=[_nav("https://www.google.com/maps")],
        tags=["maps", "navigate"],
    ),
    WorkflowSpec(
        id="search_github_trending",
        name="GitHub Trending",
        category="dev",
        prompts=["github trending", "open github trending", "trending repos github"],
        actions=[_nav("https://github.com/trending")],
        tags=["github"],
    ),
    WorkflowSpec(
        id="search_hn_frontpage",
        name="Hacker News front page",
        category="news",
        prompts=["open hacker news", "hn front page", "go to news ycombinator"],
        actions=[_nav("https://news.ycombinator.com")],
        tags=["hackernews"],
    ),
]


def catalog_by_category() -> dict[str, list[WorkflowSpec]]:
    out: dict[str, list[WorkflowSpec]] = {}
    for spec in CATALOG:
        out.setdefault(spec.category, []).append(spec)
    return out
