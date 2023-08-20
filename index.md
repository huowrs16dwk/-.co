<h1>浪人.co</h1>

<nav>
  <ul>
    {% for post in collections.posts reversed %}
      <li><a href="{{ post.url }}">{{ post.data.title }} ({{ post.data.date }})</a></li>
    {% endfor %}
  </ul>
</nav>

