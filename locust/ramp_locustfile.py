from locust import LoadTestShape

from search_locustfile import SearchUser  # noqa: F401  (the user class Locust runs)

# Gradual load: one more user every 30 s up to 30 users (15 min), then hold for 5 min
RAMP_SECONDS_PER_USER = 30
MAX_USERS = 30
HOLD_SECONDS = 300


class RampLoad(LoadTestShape):
    def tick(self):
        elapsed = self.get_run_time()
        ramp_end = RAMP_SECONDS_PER_USER * MAX_USERS
        if elapsed < ramp_end:
            return int(elapsed // RAMP_SECONDS_PER_USER) + 1, 1
        if elapsed < ramp_end + HOLD_SECONDS:
            return MAX_USERS, 1
        return None
