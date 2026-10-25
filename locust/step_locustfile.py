from locust import LoadTestShape

from search_locustfile import SearchUser  # noqa: F401  (the user class Locust runs)

# (users, seconds at that level): finds where the 0.25 vCPU task saturates
STEPS = [(1, 30), (2, 30), (3, 30), (5, 30), (10, 30), (20, 30), (40, 30)]


class StepLoad(LoadTestShape):
    def tick(self):
        elapsed = self.get_run_time()
        for users, seconds in STEPS:
            if elapsed < seconds:
                return users, users
            elapsed -= seconds
        return None
