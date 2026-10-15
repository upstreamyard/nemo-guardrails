from nemoguardrails.actions import action


@action(name="check_blocked_words")
async def check_blocked_words(text: str) -> bool:
    return "CUSTOM-BLOCK" not in text
