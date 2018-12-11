#include <stdio.h>
#include "local.h"

int main()
{
#ifdef FOO

  printf("this\
 is"
	 "a" /*
	      */ "%s %s\n",
	 "FISH" // );
	 "world");

#else
  blah();
#endif
}
