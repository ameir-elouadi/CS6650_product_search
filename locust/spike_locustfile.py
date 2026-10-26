from locust import LoadTestShape

from search_locustfile import SearchUser  # noqa: F401  (the user class Locust runs)

# (users, seconds): quiet, then everyone at once, then quiet again
STAGES = [(2, 240), (40, 720), (2, 240)]


class SpikeLoad(LoadTestShape):
    def tick(self):
        elapsed = self.get_run_time()
        for users, seconds in STAGES:
            if elapsed < seconds:
                return users, users
            elapsed -= seconds
        return None
