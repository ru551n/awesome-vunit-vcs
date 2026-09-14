import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

# Hypothesis profiles for the property-based tests: "ci" is derandomized, so a CI
# run is reproducible, with a deadline that catches pathological slowdowns;
# "dev" explores more. Select one with HYPOTHESIS_PROFILE, "ci" is the default on CI.
try:
    import os
    from datetime import timedelta

    from hypothesis import HealthCheck, settings

    settings.register_profile(
        "ci",
        derandomize=True,
        max_examples=40,
        deadline=timedelta(milliseconds=2000),
        suppress_health_check=[HealthCheck.too_slow],
    )
    settings.register_profile("dev", max_examples=100, deadline=timedelta(milliseconds=5000))
    settings.load_profile(os.environ.get("HYPOTHESIS_PROFILE", "ci" if os.environ.get("CI") else "dev"))
except ImportError:  # the property tests are skipped without Hypothesis
    pass
