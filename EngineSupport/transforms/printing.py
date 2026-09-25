"""Print/output helpers used by the app's print pipeline (page subsets)."""
from engine.errors import require
from transforms import op


@op("keep_pages")
def keep_pages(ctx, pages):
    """Keep only the given 0-based pages (document order, duplicates ignored)."""
    total = len(ctx.pdf.pages)
    require(isinstance(pages, list) and pages, "INVALID_PAGE_RANGE", "Choose at least one page.")
    wanted = set()
    for page in pages:
        require(isinstance(page, int) and 0 <= page < total, "INVALID_PAGE_RANGE",
                "Choose pages within this document.")
        wanted.add(page)
    for index in range(total - 1, -1, -1):
        if index not in wanted:
            del ctx.pdf.pages[index]
    return {"pages": len(wanted)}
