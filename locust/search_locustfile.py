import random

from locust import FastHttpUser, task, between

# Brand names, category names, and words every product name contains
SEARCH_TERMS = [
    "electronics", "books", "home", "garden", "toys", "sports",
    "alpha", "beta", "gamma", "omega", "nova", "product",
]


class SearchUser(FastHttpUser):
    # Minimal think time so each user keeps the server busy
    wait_time = between(0, 0.01)

    @task
    def search(self):
        term = random.choice(SEARCH_TERMS)
        self.client.get(f"/products/search?q={term}", name="/products/search")
