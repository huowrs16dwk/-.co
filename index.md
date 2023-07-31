<h1>浪人.co</h1>

<nav>
  <ul>
    {% for post in collections.posts %}
      <li><a href="{{ post.url }}">{{ post.data.title }}</a></li>
    {% endfor %}
  </ul>
</nav>

