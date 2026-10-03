// Connection of the LIMITED database role `hunt_app`, stored in parts.
// This role can only call the game's functions (see db/schema.sql): it cannot
// read answers, read the admin password, or modify tables directly.
// Never put the database owner's credentials here.
window.TEAMUP_CONFIG = {
  db: {
    host: 'ep-spring-salad-b2cmxqy7.c-6.eu-central-1.aws.neon.tech',
    name: 'neondb',
    user: 'hunt_app',
    key: 'Z19jMU4wb0UyNFdTcDhkTXV4TWtxYk9ZZGZJRnFhbDk='
  }
};
